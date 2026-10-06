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
# no worktree registered; the caller's tree, index bytes and HEAD untouched; and
# apply: clean / 3-way-recoverable / conflicting (exit 6, tree byte-identical) /
# empty patches; --require-clean seeing the SOURCE of a rename (quoted header paths
# too), and a failed status / path listing never read as clean; a non-repo --repo
# never falling back to the cwd's repo; the `ignored` fingerprint rule (one owner,
# sub-second mtimes, shallowest first, the one exclusion list); the per-repo
# exclusions of .triage-leakignore (absent = strict, committed only, ignored paths
# only, a non-regular file not followed, negation and root anchoring) and the opt-in
# stage links of .triage-stage-links (refusals incl. a parent outside the repo or the
# worktree and a path tracked only at the base, kept out of the patch through the
# manifest even when a candidate staged one, a candidate's own symlink kept IN,
# writes through a link still a leak, cleanup never following a link, the standalone
# `link` and `link --check`); the grants read at the bake-off's sha, never a moving
# HEAD; an unreadable opt-in file or manifest a failure, never "none"; a toolchain
# bound to the source repo refused with no override — an editable .pth / .egg-link /
# direct_url.json / __editable__ finder naming it, an absolute or RELATIVE .pth entry
# resolving into it, a symlink inside the linked path into it (node_modules/local ->
# ../packages/local), a scan that cannot finish (bound, loop, find error) — while a
# self-contained one (self references, links outside the repo) is linked; a tracked
# .triage-stage-env (retired) ignored with a notice.
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

# --- S10: an inherited GIT_DIR/GIT_WORK_TREE does not redirect staging --------
DECOY="$T/decoy"
mkrepo "$DECOY"
printf 'decoy\n' > "$DECOY/f.txt"
git -C "$DECOY" add -A && git -C "$DECOY" commit -qm decoy
DECOY_BEFORE=$({ st "$DECOY"; git -C "$DECOY" rev-parse HEAD; git -C "$DECOY" worktree list; })
D3="$T/out/stage3"
OUT=$(GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" GIT_INDEX_FILE="$DECOY/.git/index" "$SW" create --repo "$R" --base HEAD --count 1 --dir "$D3" 2>"$T/err"); RC=$?
R_HEAD=$(git -C "$R" rev-parse HEAD)
printf 'cand\n' > "$D3/wt-1/new-by-candidate.txt"
OUT2=$(GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" "$SW" diff --worktree "$D3/wt-1" --base "$R_HEAD" --out "$T/out/s10.patch" 2>/dev/null)
chk "S10 with a decoy GIT_DIR/GIT_WORK_TREE inherited, create stages --repo at its own HEAD and diff captures the candidate's file" \
  '[ "$RC" -eq 0 ] && [ "$(j .sha)" = "$R_HEAD" ] && [ "$(git -C "$D3/wt-1" rev-parse HEAD)" = "$R_HEAD" ] && printf "%s" "$OUT2" | jq -e ".ok == true" >/dev/null && grep -q "new-by-candidate.txt" "$T/out/s10.patch"'
chk "S10b ...and the decoy repo has no worktree, no new file, no index change" \
  '[ "$({ st "$DECOY"; git -C "$DECOY" rev-parse HEAD; git -C "$DECOY" worktree list; })" = "$DECOY_BEFORE" ]'
GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" "$SW" cleanup --repo "$R" --dir "$D3" >/dev/null 2>&1

# --- S11: a trailing value-taking flag is a usage error, never an endless loop ----
OUT=$(perl -e 'alarm shift; exec @ARGV' 20 "$SW" create --repo "$R" --base HEAD --count 1 --dir 2>"$T/err"); RC=$?
chk "S11 a trailing --dir with no value is exit 2 (needs a value)" '[ "$RC" -eq 2 ] && grep -q -- "--dir needs a value" "$T/err"'

# --- S12: apply — writes the caller's tree only when proven clean ----------------
AR="$T/apply-repo"
mkrepo "$AR"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$AR/f.txt"
printf 'keep\n' > "$AR/g.txt"
git -C "$AR" add -A && git -C "$AR" commit -qm base
A_BASE=$(git -C "$AR" rev-parse HEAD)
sed 's/^l5$/l5-patched/' "$AR/f.txt" > "$AR/f.new" && cat "$AR/f.new" > "$AR/f.txt" && rm -f "$AR/f.new"
git -C "$AR" diff > "$T/out/apply.patch"
git -C "$AR" checkout -q -- f.txt
: > "$T/out/empty.patch"
# tree_sum R — every working-tree file plus the index bytes (byte-identical check).
tree_sum() { ( cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done; cksum .git/index ); }

run_sw apply --repo "$AR" --patch "$T/out/apply.patch"
chk "S12 a clean patch applies (exit 0, method plain) and the change is in the tree" \
  '[ "$RC" -eq 0 ] && [ "$(j .ok)" = true ] && [ "$(j .applied)" = true ] && [ "$(j .method)" = plain ] && grep -qx l5-patched "$AR/f.txt"'
git -C "$AR" checkout -q -- f.txt

sed 's/^l2$/l2-drift/' "$AR/f.txt" > "$AR/f.new" && cat "$AR/f.new" > "$AR/f.txt" && rm -f "$AR/f.new"
git -C "$AR" commit -qam "drift inside the patch context"
run_sw apply --repo "$AR" --patch "$T/out/apply.patch"
chk "S12b a tree that drifted inside the patch context is recovered by a clean 3-way merge (method 3way, both changes, no markers)" \
  '[ "$RC" -eq 0 ] && [ "$(j .method)" = 3way ] && grep -qx l5-patched "$AR/f.txt" && grep -qx l2-drift "$AR/f.txt" && ! grep -q "^<<<<<<<" "$AR/f.txt"'
git -C "$AR" reset -q --hard "$A_BASE"

sed 's/^l5$/l5-theirs/' "$AR/f.txt" > "$AR/f.new" && cat "$AR/f.new" > "$AR/f.txt" && rm -f "$AR/f.new"
git -C "$AR" commit -qam "a conflicting change to the patched line"
printf 'untracked wip\n' > "$AR/wip.txt"
printf 'unstaged wip\n' >> "$AR/g.txt"
git -C "$AR" update-index --refresh >/dev/null 2>&1
A_SUM=$(tree_sum "$AR"); A_HEAD=$(git -C "$AR" rev-parse HEAD)
run_sw apply --repo "$AR" --patch "$T/out/apply.patch"
chk "S12c a CONFLICTING patch is refused with exit 6, ok:false, nothing applied" \
  '[ "$RC" -eq 6 ] && [ "$(j .ok)" = false ] && [ "$(j .applied)" = false ] && j .error | grep -q "nothing was written"'
chk "S12d ...and the tree (files, untracked + unstaged work, index bytes, HEAD) is byte-identical, no conflict markers" \
  '[ "$(tree_sum "$AR")" = "$A_SUM" ] && [ "$(git -C "$AR" rev-parse HEAD)" = "$A_HEAD" ] && ! grep -q "^<<<<<<<" "$AR/f.txt" && grep -qx l5-theirs "$AR/f.txt"'
run_sw apply --repo "$AR" --patch "$T/out/empty.patch"
chk "S12e an empty patch is a no-op success (method empty) and changes nothing" \
  '[ "$RC" -eq 0 ] && [ "$(j .ok)" = true ] && [ "$(j .applied)" = false ] && [ "$(j .method)" = empty ] && [ "$(tree_sum "$AR")" = "$A_SUM" ]'
run_sw apply --repo "$AR" --patch "out/apply.patch"
chk "S12f a relative --patch is a usage error (exit 2)" '[ "$RC" -eq 2 ] && [ "$(tree_sum "$AR")" = "$A_SUM" ]'
OUT=$(GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" "$SW" apply --repo "$AR" --patch "$T/out/empty.patch" 2>"$T/err"); RC=$?
chk "S12g apply resolves --repo itself even with a decoy GIT_DIR inherited" '[ "$RC" -eq 0 ] && [ "$(j .repo)" = "$AR" ] && [ "$({ st "$DECOY"; git -C "$DECOY" rev-parse HEAD; git -C "$DECOY" worktree list; })" = "$DECOY_BEFORE" ]'

# --- S13: apply --require-clean and treeModified (M3, M4) ----------------------
git -C "$AR" reset -q --hard "$A_BASE"; rm -f "$AR/wip.txt"
run_sw apply --repo "$AR" --patch "$T/out/apply.patch"
chk "S13 a successful apply reports treeModified:true" '[ "$RC" -eq 0 ] && [ "$(j .treeModified)" = true ]'
git -C "$AR" checkout -q -- f.txt
printf 'unstaged wip in a patched file\n' >> "$AR/f.txt"
B13=$(tree_sum "$AR")
run_sw apply --repo "$AR" --patch "$T/out/apply.patch" --require-clean
chk "S13b --require-clean: a patch touching a file with uncommitted work is exit 6, nothing written, the path named" \
  '[ "$RC" -eq 6 ] && [ "$(j .applied)" = false ] && [ "$(j .treeModified)" = false ] && j .error | grep -q "f.txt" && [ "$(tree_sum "$AR")" = "$B13" ]'
run_sw apply --repo "$AR" --patch "$T/out/apply.patch"
chk "S13c ...where without --require-clean the same apply would have written on top of that work" \
  '[ "$RC" -eq 0 ] && grep -qx l5-patched "$AR/f.txt"'
git -C "$AR" checkout -q -- f.txt
printf 'wip elsewhere\n' >> "$AR/g.txt"
run_sw apply --repo "$AR" --patch "$T/out/apply.patch" --require-clean
chk "S13d --require-clean ignores uncommitted work OUTSIDE the patch's paths (applies)" '[ "$RC" -eq 0 ] && [ "$(j .method)" = plain ]'
git -C "$AR" checkout -q -- f.txt g.txt
( cd "$AR" && printf 'n\n' > newf.txt && git add newf.txt && git diff --cached > "$T/out/newf.patch" && git reset -q && rm -f newf.txt )
printf 'untracked squatter\n' > "$AR/newf.txt"
run_sw apply --repo "$AR" --patch "$T/out/newf.patch" --require-clean
chk "S13e --require-clean: an untracked file where the patch creates one is exit 6" '[ "$RC" -eq 6 ] && [ "$(cat "$AR/newf.txt")" = "untracked squatter" ]'
rm -f "$AR/newf.txt"
# A git shim: the WRITE step of an apply fails — a 3-way leaving conflict markers,
# or a plain apply writing nothing — after its clean pre-check.
SHIM="$T/shim"; mkdir -p "$SHIM"; REALGIT=$(command -v git)
cat > "$SHIM/git" <<SHIMEOF
#!/bin/bash
ap=0 ck=0 tw=0 ns=0
for a in "\$@"; do case "\$a" in apply) ap=1 ;; --check) ck=1 ;; --3way) tw=1 ;; --numstat) ns=1 ;; esac; done
if [ "\${SHIM_MODE:-}" = statusfail ]; then for a in "\$@"; do [ "\$a" = status ] && { echo "fatal: shim status failure" >&2; exit 128; }; done; fi
if { [ "\${SHIM_MODE:-}" = numstatfail ] || [ "\${SHIM_NUMSTAT_FAIL:-}" = 1 ]; } && [ \$ns = 1 ]; then echo "fatal: shim numstat failure" >&2; exit 128; fi
if [ \$ap = 1 ] && [ \$ck = 0 ] && [ \$ns = 0 ]; then
  if [ "\${SHIM_MODE:-}" = markers ] && [ \$tw = 1 ]; then printf '<<<<<<< ours\n' >> "\$SHIM_FILE"; exit 1; fi
  if [ "\${SHIM_MODE:-}" = plainfail ] && [ \$tw = 0 ]; then exit 1; fi
fi
exec "$REALGIT" "\$@"
SHIMEOF
chmod +x "$SHIM/git"
sed 's/^l2$/l2-drift/' "$AR/f.txt" > "$AR/f.new" && cat "$AR/f.new" > "$AR/f.txt" && rm -f "$AR/f.new"
git -C "$AR" commit -qam "drift inside the patch context (forces the 3-way path)"
OUT=$(PATH="$SHIM:$PATH" SHIM_MODE=markers SHIM_FILE="$AR/f.txt" "$SW" apply --repo "$AR" --patch "$T/out/apply.patch" 2>"$T/err"); RC=$?
chk "S13f a 3-way write that fails after a clean pre-check and leaves conflict markers: exit 1, treeModified:true (M4)" \
  '[ "$RC" -eq 1 ] && [ "$(j .applied)" = false ] && [ "$(j .method)" = 3way ] && [ "$(j .treeModified)" = true ] && grep -q "^<<<<<<<" "$AR/f.txt"'
git -C "$AR" reset -q --hard "$A_BASE"
OUT=$(PATH="$SHIM:$PATH" SHIM_MODE=plainfail "$SW" apply --repo "$AR" --patch "$T/out/apply.patch" 2>"$T/err"); RC=$?
chk "S13g a plain write that fails without writing: exit 1, treeModified:false (measured, not assumed)" \
  '[ "$RC" -eq 1 ] && [ "$(j .method)" = plain ] && [ "$(j .treeModified)" = false ] && ! grep -q l5-patched "$AR/f.txt"'

# --- S15: --require-clean sees the SOURCE of a rename; a failed listing is never clean (M4, L5)
git -C "$AR" reset -q --hard "$A_BASE"
( cd "$AR" && git mv g.txt renamed.txt && git diff --cached -M HEAD > "$T/out/rename.patch" && git reset -q --hard )
printf 'uncommitted edit to the rename source\n' >> "$AR/g.txt"
B15=$(tree_sum "$AR")
run_sw apply --repo "$AR" --patch "$T/out/rename.patch" --require-clean
chk "S15 --require-clean: a rename whose SOURCE has uncommitted work is exit 6, the source named, the tree byte-identical" \
  '[ "$RC" -eq 6 ] && [ "$(j .applied)" = false ] && [ "$(j .treeModified)" = false ] && j .error | grep -q "g.txt" && [ "$(tree_sum "$AR")" = "$B15" ] && [ ! -e "$AR/renamed.txt" ]'
git -C "$AR" checkout -q -- g.txt
run_sw apply --repo "$AR" --patch "$T/out/rename.patch" --require-clean
chk "S15b ...and with a clean source the same rename applies, treeModified:true" \
  '[ "$RC" -eq 0 ] && [ "$(j .treeModified)" = true ] && [ -f "$AR/renamed.txt" ] && [ ! -e "$AR/g.txt" ]'
git -C "$AR" reset -q --hard "$A_BASE"; git -C "$AR" clean -fdq
( cd "$AR" && git mv g.txt "sp ace\303\251.txt" 2>/dev/null || git mv g.txt "$(printf 'sp ace\303\251.txt')"; git -c core.quotePath=true diff --cached -M HEAD > "$T/out/rename-q.patch"; git reset -q --hard )
printf 'edit\n' >> "$AR/g.txt"
run_sw apply --repo "$AR" --patch "$T/out/rename-q.patch" --require-clean
chk "S15c a rename with QUOTED header paths (space, non-ASCII) still has its dirty source refused" \
  'grep -q "^rename from g.txt" "$T/out/rename-q.patch" && [ "$RC" -eq 6 ] && j .error | grep -q "g.txt"'
git -C "$AR" reset -q --hard "$A_BASE"; git -C "$AR" clean -fdq
B15D=$(tree_sum "$AR")
OUT=$(PATH="$SHIM:$PATH" SHIM_MODE=statusfail "$SW" apply --repo "$AR" --patch "$T/out/apply.patch" --require-clean 2>"$T/err"); RC=$?
chk "S15d --require-clean: a git status that FAILS is exit 6, treeModified:false, nothing written (never read as clean)" \
  '[ "$RC" -eq 6 ] && [ "$(j .applied)" = false ] && [ "$(j .treeModified)" = false ] && j .error | grep -q "git status failed" && [ "$(tree_sum "$AR")" = "$B15D" ]'
OUT=$(PATH="$SHIM:$PATH" SHIM_MODE=numstatfail "$SW" apply --repo "$AR" --patch "$T/out/apply.patch" --require-clean 2>"$T/err"); RC=$?
chk "S15e --require-clean: a path listing that FAILS is exit 6, treeModified:false, nothing written" \
  '[ "$RC" -eq 6 ] && [ "$(j .treeModified)" = false ] && j .error | grep -q "could not list" && [ "$(tree_sum "$AR")" = "$B15D" ]'

OUT=$(PATH="$SHIM:$PATH" SHIM_MODE=plainfail SHIM_NUMSTAT_FAIL=1 "$SW" apply --repo "$AR" --patch "$T/out/apply.patch" 2>"$T/err"); RC=$?
chk "S15g a failed write whose paths could not be listed reports treeModified:true (unknown is never clean)" \
  '[ "$RC" -eq 1 ] && [ "$(j .applied)" = false ] && [ "$(j .treeModified)" = true ]'
git -C "$AR" reset -q --hard "$A_BASE"; git -C "$AR" clean -fdq
# A perl shim that fails only the rename/copy header parse: numstat still lists the
# new side, so the list is PARTIAL — never treated as clean.
PSHIM="$T/pshim"; mkdir -p "$PSHIM"; REALPERL=$(command -v perl)
printf '#!/bin/bash\ncase "$*" in *"rename|copy) from"*) exit 2 ;; esac\nexec "%s" "$@"\n' "$REALPERL" > "$PSHIM/perl"; chmod +x "$PSHIM/perl"
printf 'uncommitted edit to the rename source\n' >> "$AR/g.txt"
B15H=$(tree_sum "$AR")
OUT=$(PATH="$PSHIM:$PATH" "$SW" apply --repo "$AR" --patch "$T/out/rename.patch" --require-clean 2>"$T/err"); RC=$?
chk "S15h --require-clean: a FAILED header parse (numstat still listing the new side) is never clean: exit 6, the dirty source untouched" \
  '[ "$RC" -eq 6 ] && [ "$(j .applied)" = false ] && [ "$(tree_sum "$AR")" = "$B15H" ] && [ ! -e "$AR/renamed.txt" ]'
git -C "$AR" reset -q --hard "$A_BASE"; git -C "$AR" clean -fdq
B15F=$(tree_sum "$AR")
OUT=$(cd "$AR" && "$SW" apply --repo "$T/not-a-repo" --patch "$T/out/apply.patch" 2>"$T/err"); RC=$?
chk "S15f a --repo that is not a git work tree is exit 2 even from INSIDE another repo — never applied to the cwd's repo" \
  '[ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ "$(tree_sum "$AR")" = "$B15F" ] && ! grep -qx l5-patched "$AR/f.txt"'

# --- S14: leakcheck --line, ignored paths (H4 reduced, H5) ---------------------
IR="$T/ign-repo"
mkrepo "$IR"
printf 'build/\n*.cache\n' > "$IR/.gitignore"
printf 'x\n' > "$IR/x.txt"
git -C "$IR" add -A && git -C "$IR" commit -qm one
mkdir -p "$IR/build"; printf 'old artifact\n' > "$IR/build/out.bin"
D4="$T/out/stage4"
run_sw create --repo "$IR" --base HEAD --count 1 --dir "$D4"
run_sw leakcheck --repo "$IR" --dir "$D4" --line
chk "S14 --line prints ONE line 'LEAKCHECK {json}' carrying rc, status and the sha" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 1 ] && case "$OUT" in "LEAKCHECK {"*) true ;; *) false ;; esac &&
   [ "$(printf "%s" "${OUT#LEAKCHECK }" | jq -r ".status + \" \" + (.rc|tostring)")" = "CLEAN 0" ] && [ "$(printf "%s" "${OUT#LEAKCHECK }" | jq -r .sha)" = "$(git -C "$IR" rev-parse HEAD)" ]'
printf 'rewritten by a candidate\n' > "$IR/build/out.bin"
run_sw leakcheck --repo "$IR" --dir "$D4" --line
chk "S14b a write to an IGNORED file in the real repo is a LEAK (the cache/build-output class): rc 7 in the line" \
  '[ "$RC" -eq 7 ] && [ "$(printf "%s" "${OUT#LEAKCHECK }" | jq -r ".status + \" \" + (.rc|tostring)")" = "LEAK 7" ] && printf "%s" "${OUT#LEAKCHECK }" | jq -e ".paths | index(\"build/out.bin\") != null" >/dev/null'
printf 'old artifact\n' > "$IR/build/out.bin"
printf 'new cache\n' > "$IR/new.cache"
run_sw leakcheck --repo "$IR" --dir "$D4"
chk "S14c a NEW ignored file is a LEAK too (plain JSON without --line)" '[ "$RC" -eq 7 ] && [ "$(j .status)" = LEAK ] && [ "$(j .rc)" = null ]'
rm -f "$IR/new.cache"
run_sw leakcheck --repo "$IR" --dir "$D4"
chk "S14d restored → CLEAN again" '[ "$RC" -eq 0 ] && [ "$(j .status)" = CLEAN ]'
printf '.claude/agent-memory/\nPROJECT_MEMORY*.md\n' >> "$IR/.git/info/exclude"
mkdir -p "$IR/.claude/agent-memory/x"; printf 'a note\n' > "$IR/.claude/agent-memory/x/m.md"; printf 'entry\n' > "$IR/PROJECT_MEMORY.md"
run_sw leakcheck --repo "$IR" --dir "$D4"
chk "S14f IGNORED agent bookkeeping written mid-run (.claude/, PROJECT_MEMORY*.md) is not a leak" '[ "$RC" -eq 0 ] && [ "$(j .status)" = CLEAN ]'
rm -rf "$IR/.claude" "$IR/PROJECT_MEMORY.md"
# diff: what the patch cannot carry is reported.
mkdir -p "$D4/wt-1/build"; printf 'candidate artifact\n' > "$D4/wt-1/build/new.bin"; printf 'ok\n' > "$D4/wt-1/.parity-env"
printf 'y\n' > "$D4/wt-1/y.txt"
NESTED="$D4/wt-1/vendored"; mkrepo "$NESTED"; printf 'v\n' > "$NESTED/v.txt"; git -C "$NESTED" add -A && git -C "$NESTED" commit -qm v
run_sw diff --worktree "$D4/wt-1" --base "$(git -C "$IR" rev-parse HEAD)" --out "$T/out/ign.patch"
chk "S14e diff reports ignoredNew (build/new.bin; the harness's .parity-env not counted) and the nested repo as a gitlink" \
  '[ "$RC" -eq 0 ] && [ "$(j .ignoredNew)" = 1 ] && [ "$(j ".gitlinks | join(\",\")")" = vendored ]'
run_sw cleanup --repo "$IR" --dir "$D4"

# --- S16: the IGNORED fingerprint — one owner, sub-second mtimes (M10, L1) -----
mkdir -p "$IR/build/deep/er"
head -c 300000 /dev/zero | tr '\000' a > "$IR/build/big.bin"     # over the 256 KiB hash limit: size + mtime
touch -d 2020-01-01T00:00:00.1 "$IR/build/big.bin"
printf 'd\n' > "$IR/build/deep/er/d.bin"; printf 'mac\n' > "$IR/build/.DS_Store"
D5="$T/out/stage5"
run_sw create --repo "$IR" --base HEAD --count 1 --dir "$D5"
head -c 300000 /dev/zero | tr '\000' b > "$IR/build/big.bin"     # same size, rewritten "within the same second"
touch -d 2020-01-01T00:00:00.7 "$IR/build/big.bin"
run_sw leakcheck --repo "$IR" --dir "$D5"
chk "S16 a same-size rewrite of a large ignored file within one second is a LEAK (sub-second mtime, L1)" \
  '[ "$RC" -eq 7 ] && [ "$(j .status)" = LEAK ] && [ "$(j ".paths | index(\"build/big.bin\") != null")" = true ]'
run_sw cleanup --repo "$IR" --dir "$D5"
run_sw ignored --repo "$IR"
chk "S16b ignored prints the rule: content hash for small files, size+mtime for big ones, .DS_Store / .claude/ / PROJECT_MEMORY*.md left out" \
  '[ "$RC" -eq 0 ] && printf "%s\n" "$OUT" | grep -q "^build/out.bin	ign:[0-9a-f]\{40\}$" && printf "%s\n" "$OUT" | grep -q "^build/big.bin	ign-meta:300000:" && ! printf "%s" "$OUT" | grep -q "DS_Store"'
IGN0="$OUT"
STAGE_WT_IGN_LIST_MAX=2 run_sw ignored --repo "$IR"
chk "S16c past the list cap, paths are taken shallowest first and the rest only counted (ign-count)" \
  '[ "$RC" -eq 0 ] && printf "%s\n" "$OUT" | grep -q "ign-count:3" && ! printf "%s" "$OUT" | grep -q "deep/er/d.bin"'
run_sw ignored --repo "$T/nope"
chk "S16d ignored on a non-repo is a usage error (exit 2)" '[ "$RC" -eq 2 ]'
# ONE owner: the two other leak fingerprints call `stage-worktree.sh ignored`, never
# list ignored files themselves.
uses_owner() { grep -q "stage-worktree.sh" "$1" && grep -q "ignored --repo" "$1" && ! grep -qE "ls-files[^|]* -(o -i|i -o)|ls-files[^|]*--ignored" "$1"; }
chk "S16e review-stage.sh and parity-suite.sh take the IGNORED fingerprint from stage-worktree.sh ignored (no copy of the rule)" \
  'uses_owner "$REPO_DIR/scripts/review-stage.sh" && uses_owner "$REPO_DIR/scripts/parity-suite.sh"'

# --- S17: per-repo leak exclusions — HEAD:.triage-leakignore ---------------------
LR="$T/leak-repo"
mkrepo "$LR"
printf 'data/\nbuild/\n' > "$LR/.gitignore"
printf 'x\n' > "$LR/x.txt"
git -C "$LR" add -A && git -C "$LR" commit -qm one
mkdir -p "$LR/data/checkin" "$LR/build"
printf 'db v1\n' > "$LR/data/coach.sqlite"; printf 'old\n' > "$LR/build/out.bin"
# Absent file: today's strict behaviour, byte for byte.
run_sw ignored --repo "$LR"
chk "S17a no .triage-leakignore: ignored lists data/ and prints no leakignore line" \
  '[ "$RC" -eq 0 ] && printf "%s\n" "$OUT" | grep -q "^data/coach.sqlite	ign:" && ! printf "%s" "$OUT" | grep -q leakignore && [ -z "$ERR" ]'
# A working-tree-only file is never read (HEAD only).
printf 'data/\n' > "$LR/.triage-leakignore"
run_sw ignored --repo "$LR"
chk "S17b an UNCOMMITTED .triage-leakignore is not read: data/ still listed" \
  '[ "$RC" -eq 0 ] && printf "%s\n" "$OUT" | grep -q "^data/coach.sqlite	ign:" && ! printf "%s" "$OUT" | grep -q leakignore'
D7="$T/out/stage7"
run_sw create --repo "$LR" --base HEAD --count 1 --dir "$D7"
chk "S17c create without a committed file: leakignore null, no links" \
  '[ "$RC" -eq 0 ] && [ "$(j .leakignore)" = null ] && [ "$(j ".links | length")" = 0 ] && [ "$(j ".linkRefused | length")" = 0 ] && [ ! -e "$D7/fingerprint.leakignore" ]'
printf 'db v2\n' > "$LR/data/coach.sqlite"
run_sw leakcheck --repo "$LR" --dir "$D7" --line
chk "S17d without a committed file a daemon write to data/ is still a LEAK (leakignore null in the line)" \
  '[ "$RC" -eq 7 ] && [ "$(printf "%s" "${OUT#LEAKCHECK }" | jq -r ".status + \" \" + (.leakignore|tostring)")" = "LEAK null" ]'
run_sw cleanup --repo "$LR" --dir "$D7"
printf 'db v1\n' > "$LR/data/coach.sqlite"
# Committed: data/ excluded.
printf '# coach daemon output\ndata/\n' > "$LR/.triage-leakignore"
git -C "$LR" add .triage-leakignore && git -C "$LR" commit -qm leakignore
run_sw ignored --repo "$LR"
chk "S17e a COMMITTED .triage-leakignore leaves its ignored paths out and adds ONE leakignore line (the blob sha)" \
  '[ "$RC" -eq 0 ] && ! printf "%s" "$OUT" | grep -q "^data/" && printf "%s\n" "$OUT" | grep -q "^build/out.bin	ign:" &&
   printf "%s\n" "$OUT" | grep -qx "	leakignore:$(git -C "$LR" rev-parse HEAD:.triage-leakignore)" && printf "%s" "$ERR" | grep -q "1 ignored path(s) left out"'
D8="$T/out/stage8"
run_sw create --repo "$LR" --base HEAD --count 1 --dir "$D8"
chk "S17f create reports the patterns (comments dropped) and the excluded count" \
  '[ "$RC" -eq 0 ] && [ "$(j ".leakignore.patterns | join(\",\")")" = "data/" ] && [ "$(j .leakignore.excluded)" = 1 ] && [ "$(j .leakignore.file)" = .triage-leakignore ]'
printf 'db v2\n' > "$LR/data/coach.sqlite"; printf '{}\n' > "$LR/data/checkin/2026-10-05.json"
run_sw leakcheck --repo "$LR" --dir "$D8" --line
chk "S17g daemon writes under an excluded ignored dir are CLEAN; the line carries patterns + excluded count" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "${OUT#LEAKCHECK }" | jq -r ".status + \" \" + (.leakignore.excluded|tostring) + \" \" + (.leakignore.patterns|join(\",\"))")" = "CLEAN 2 data/" ]'
printf 'rewritten\n' > "$LR/build/out.bin"
run_sw leakcheck --repo "$LR" --dir "$D8"
chk "S17h an ignored path the patterns do not match is still a LEAK" \
  '[ "$RC" -eq 7 ] && [ "$(j ".paths | join(\",\")")" = build/out.bin ]'
printf 'old\n' > "$LR/build/out.bin"
# An uncommitted widening is never read: leakcheck keeps create's copy.
printf '*\n' > "$LR/.triage-leakignore"; git -C "$LR" update-index --assume-unchanged .triage-leakignore
printf 'rewritten\n' > "$LR/build/out.bin"
run_sw leakcheck --repo "$LR" --dir "$D8"
chk "S17i a working-tree widening of the patterns (to *) does not hide an ignored write" \
  '[ "$RC" -eq 7 ] && [ "$(j ".paths | index(\"build/out.bin\") != null")" = true ] && [ "$(j ".leakignore.patterns | join(\",\")")" = "data/" ]'
git -C "$LR" update-index --no-assume-unchanged .triage-leakignore
git -C "$LR" checkout -q -- .triage-leakignore; printf 'old\n' > "$LR/build/out.bin"
run_sw cleanup --repo "$LR" --dir "$D8"
# Even '*' committed: tracked and untracked-not-ignored paths are never excludable.
printf '*\n' > "$LR/.triage-leakignore"
git -C "$LR" add .triage-leakignore && git -C "$LR" commit -qm widen
D9="$T/out/stage9"
run_sw create --repo "$LR" --base HEAD --count 1 --dir "$D9"
printf 'edited\n' > "$LR/x.txt"; printf 'new\n' > "$LR/stray.txt"; printf 'rewritten\n' > "$LR/build/out.bin"
run_sw leakcheck --repo "$LR" --dir "$D9"
chk "S17j a committed '*' never excludes a tracked edit or a new untracked-not-ignored file (only ignored paths)" \
  '[ "$RC" -eq 7 ] && [ "$(j ".paths | join(\",\")")" = "stray.txt,x.txt" ]'
git -C "$LR" checkout -q -- x.txt; rm -f "$LR/stray.txt"; printf 'old\n' > "$LR/build/out.bin"
run_sw cleanup --repo "$LR" --dir "$D9"
# A non-regular-file entry (a committed symlink) is ignored: strict.
git -C "$LR" rm -q .triage-leakignore; ln -s .gitignore "$LR/.triage-leakignore"
git -C "$LR" add .triage-leakignore && git -C "$LR" commit -qm symlink
run_sw ignored --repo "$LR"
chk "S17k a committed SYMLINK .triage-leakignore is not followed: no exclusions" \
  '[ "$RC" -eq 0 ] && printf "%s\n" "$OUT" | grep -q "^data/coach.sqlite	ign:" && ! printf "%s" "$OUT" | grep -q "	leakignore:"'
# An uncommitted widening of a COMMITTED file: `ignored` (and create) read HEAD's copy.
git -C "$LR" rm -q .triage-leakignore; printf 'data/\n' > "$LR/.triage-leakignore"
git -C "$LR" add .triage-leakignore && git -C "$LR" commit -qm regular
printf '*\n' > "$LR/.triage-leakignore"
run_sw ignored --repo "$LR"
chk "S17l with the committed file widened in the working tree (to *), ignored still uses HEAD's patterns" \
  '[ "$RC" -eq 0 ] && printf "%s\n" "$OUT" | grep -q "^build/out.bin	ign:" && ! printf "%s" "$OUT" | grep -q "^data/" &&
   printf "%s\n" "$OUT" | grep -qx "	leakignore:$(git -C "$LR" rev-parse HEAD:.triage-leakignore)"'
# Patterns committed MID-RUN are not picked up: leakcheck keeps create's copy.
printf 'data/\nbuild/\n' > "$LR/.triage-leakignore"
D13="$T/out/stage13"
run_sw create --repo "$LR" --base HEAD --count 1 --dir "$D13"
git -C "$LR" commit -qam widen-mid-run
run_sw leakcheck --repo "$LR" --dir "$D13"
chk "S17m a .triage-leakignore committed after create is not re-read: BASE_MOVED under the stage's own patterns" \
  '[ "$RC" -eq 0 ] && [ "$(j .status)" = BASE_MOVED ] && [ "$(j ".leakignore.patterns | join(\",\")")" = "data/" ] && [ "$(j .leakignore.excluded)" = 2 ]'
run_sw cleanup --repo "$LR" --dir "$D13"

# --- S18: opt-in stage links — HEAD:.triage-stage-links ---------------------------
KR="$T/link-repo"
mkrepo "$KR"
printf '.venv/\nnode_modules\n*.pyc\n__pycache__/\n' > "$KR/.gitignore"
printf 'print(1)\n' > "$KR/src.py"
git -C "$KR" add -A && git -C "$KR" commit -qm one
mkdir -p "$KR/.venv/bin" "$KR/node_modules/m" "$KR/plain" "$T/elsewhere"
printf '#!/bin/sh\necho venv-ok\n' > "$KR/.venv/bin/python"; chmod +x "$KR/.venv/bin/python"
printf 'm\n' > "$KR/node_modules/m/i.js"; printf 'p\n' > "$KR/plain/f"
ln -s "$T/elsewhere" "$KR/outlink"; printf 'outlink\n' >> "$KR/.git/info/exclude"
# Absent file: no links (S17c covers create's JSON), and a working-tree-only list is never read.
printf '.venv\n' > "$KR/.triage-stage-links"
D10="$T/out/stage10"
run_sw create --repo "$KR" --base HEAD --count 1 --dir "$D10"
chk "S18a an UNCOMMITTED .triage-stage-links is not read: nothing linked" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | length")" = 0 ] && [ ! -e "$D10/wt-1/.venv" ] && [ ! -L "$D10/wt-1/.venv" ]'
run_sw cleanup --repo "$KR" --dir "$D10"
printf '# toolchain\n.venv/\nnode_modules\n/abs/venv\n../up\na/./b\nsrc.py\nmissing\nplain\noutlink\n\n' > "$KR/.triage-stage-links"
git -C "$KR" add .triage-stage-links && git -C "$KR" commit -qm links
KHEAD=$(git -C "$KR" rev-parse HEAD)
D11="$T/out/stage11"
run_sw create --repo "$KR" --base HEAD --count 2 --dir "$D11"
reason_of() { j ".linkRefused[] | select(.path == \"$1\") | .reason"; }
chk "S18b create links .venv (trailing / dropped) and node_modules into EVERY worktree, pointing at the repo" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | join(\",\")")" = ".venv,node_modules" ] &&
   [ "$(readlink "$D11/wt-1/.venv")" = "$KR/.venv" ] && [ "$(readlink "$D11/wt-2/node_modules")" = "$KR/node_modules" ] &&
   [ "$("$D11/wt-2/.venv/bin/python")" = venv-ok ]'
chk "S18c refusals: absolute, .., unnormalized, tracked, missing, not gitignored, a symlink in the repo — listed, warned, not linked" \
  '[ "$(reason_of /abs/venv)" = "absolute path" ] && [ "$(reason_of ../up)" = "contains a .. component" ] &&
   [ "$(reason_of a/./b)" = "not a normalized repo-relative path" ] && [ "$(reason_of src.py)" = "tracked in the repo" ] &&
   [ "$(reason_of missing)" = "does not exist in the repo" ] && [ "$(reason_of plain)" = "not gitignored in the repo" ] &&
   [ "$(reason_of outlink)" = "a symlink in the repo" ] && [ ! -e "$D11/wt-1/plain" ] && [ ! -L "$D11/wt-1/outlink" ] &&
   [ -f "$D11/wt-1/src.py" ] && [ ! -L "$D11/wt-1/src.py" ] && printf "%s" "$ERR" | grep -q "NOT linked"'
printf 'print(2)\n' > "$D11/wt-1/src.py"
run_sw diff --worktree "$D11/wt-1" --base "$KHEAD" --out "$T/out/link.patch"
chk "S18d diff keeps the stage links out of the patch and out of ignoredNew" \
  '[ "$RC" -eq 0 ] && [ "$(j .ignoredNew)" = 0 ] && grep -q "^+print(2)" "$T/out/link.patch" && ! grep -qE "venv|node_modules" "$T/out/link.patch" &&
   [ "$(git -C "$D11/wt-1" diff --cached --name-only "$KHEAD")" = src.py ]'
printf 'pkg\n' > "$D11/wt-1/.venv/bin/new-tool"
run_sw leakcheck --repo "$KR" --dir "$D11"
chk "S18e a write THROUGH a link lands in the repo and is a LEAK (no leakignore)" \
  '[ "$RC" -eq 7 ] && [ "$(j ".paths | join(\",\")")" = ".venv/bin/new-tool" ]'
rm -f "$KR/.venv/bin/new-tool"
run_sw cleanup --repo "$KR" --dir "$D11"
chk "S18f cleanup removes the links, never what they point at" \
  '[ "$RC" -eq 0 ] && [ ! -e "$D11" ] && [ -x "$KR/.venv/bin/python" ] && [ -f "$KR/node_modules/m/i.js" ]'
# With a leakignore for bytecode under the linked venv, that write is excluded.
printf '.venv/**/__pycache__/\n' > "$KR/.triage-leakignore"
git -C "$KR" add .triage-leakignore && git -C "$KR" commit -qm pyc
D12="$T/out/stage12"
run_sw create --repo "$KR" --base HEAD --count 1 --dir "$D12"
mkdir -p "$D12/wt-1/.venv/lib/__pycache__"; printf 'pyc\n' > "$D12/wt-1/.venv/lib/__pycache__/m.cpython.pyc"
run_sw leakcheck --repo "$KR" --dir "$D12"
chk "S18g a bytecode write through a linked venv is CLEAN when .triage-leakignore excludes it" \
  '[ "$RC" -eq 0 ] && [ "$(j .status)" = CLEAN ] && [ "$(j .leakignore.excluded)" = 1 ]'
# link, standalone: a grading worktree of the same repo gets the same links; refusals.
GW="$T/out/grade-wt"
git -C "$KR" worktree add -q --detach "$GW" HEAD
run_sw link --repo "$KR" --base HEAD --worktree "$GW"
chk "S18h link gives any linked worktree of the repo the same links (one JSON line)" \
  '[ "$RC" -eq 0 ] && [ "$(j .step)" = link ] && [ "$(j ".links | join(\",\")")" = ".venv,node_modules" ] && [ "$(readlink "$GW/.venv")" = "$KR/.venv" ]'
run_sw link --repo "$KR" --base HEAD --worktree "$GW"
chk "S18i linking again refuses what already exists in the worktree" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | length")" = 0 ] && [ "$(j "[.refused[] | select(.reason == \"already exists in the worktree\")] | length")" = 2 ]'
run_sw link --repo "$KR" --base HEAD --worktree "$KR"
chk "S18j link refuses the repo's own (main) working tree: usage error, nothing linked" \
  '[ "$RC" -eq 2 ] && [ ! -L "$KR/.venv" ] && [ -d "$KR/.venv" ]'
run_sw link --repo "$LR" --base HEAD --worktree "$GW"
chk "S18k link refuses a worktree of ANOTHER repo" '[ "$RC" -eq 2 ]'
run_sw link --repo "$GW" --base HEAD --worktree "$KR"
chk "S18l link refuses a MAIN working tree as --worktree even when --repo is a linked worktree of it" \
  '[ "$RC" -eq 2 ] && [ ! -L "$KR/.venv" ] && [ -d "$KR/.venv" ]'
git -C "$KR" worktree remove --force "$GW"
run_sw cleanup --repo "$KR" --dir "$D12"

# --- S19: the link manifest, frozen grants, failures, bound toolchains, stage env ----
BR="$T/bind-repo"
mkrepo "$BR"
printf '.venv/\ncache/\nvenv/\next\ntools/\n' > "$BR/.gitignore"
mkdir -p "$BR/src/pkg" "$BR/cache"; printf 'WHO = "source"\n' > "$BR/src/pkg/__init__.py"; printf 'c\n' > "$BR/cache/x"
printf '.venv\ncache\n' > "$BR/.triage-stage-links"
git -C "$BR" add .gitignore src .triage-stage-links && git -C "$BR" commit -qm one
git -C "$BR" add -f cache/x && git -C "$BR" commit -qm cache-tracked
BOLD=$(git -C "$BR" rev-parse HEAD)
git -C "$BR" rm -q --cached cache/x && git -C "$BR" commit -qm cache-untracked
B1=$(git -C "$BR" rev-parse HEAD)
mkdir -p "$BR/.venv/bin" "$BR/.venv/lib/site-packages"
printf '#!/bin/sh\necho venv\n' > "$BR/.venv/bin/tool"; chmod +x "$BR/.venv/bin/tool"
D20="$T/out/stage20"
run_sw create --repo "$BR" --base HEAD --count 1 --dir "$D20"
MF=$(git -C "$D20/wt-1" rev-parse --absolute-git-dir)/triage-stage-links
chk "S19a create records every link it makes in the worktree's manifest (its own git dir); no stage env anywhere" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | join(\",\")")" = ".venv,cache" ] && [ "$(cat "$MF" | paste -sd, -)" = ".venv,cache" ] &&
   [ "$(j "has(\"env\") or has(\"envRefused\")")" = false ] && [ ! -e "$D20/wt-1.env" ] && [ ! -e "$D20/wt-1/triage-stage-links" ]'
# A candidate's own `git add -A` stages the .venv symlink (.venv/ does not match the FILE).
printf 'print(2)\n' > "$D20/wt-1/src/pkg/__init__.py"
git -C "$D20/wt-1" add -A
STAGED_BEFORE=$(git -C "$D20/wt-1" diff --cached --name-only | paste -sd, -)
# …and creates its OWN symlinks: one spelled like a stage link (<repo>/P), one relative.
ln -s "$BR/new-unlisted" "$D20/wt-1/new-unlisted"; ln -s src/pkg "$D20/wt-1/pkglink"
run_sw diff --worktree "$D20/wt-1" --base HEAD --out "$T/out/s19.patch"
chk "S19b a stage link a candidate already STAGED is unstaged again: never in the patch (the link itself stays)" \
  'printf "%s" "$STAGED_BEFORE" | grep -q "\.venv" && [ "$RC" -eq 0 ] && [ "$(j .ok)" = true ] && ! grep -q "\.venv" "$T/out/s19.patch" &&
   ! git -C "$D20/wt-1" diff --cached --name-only HEAD | grep -qx .venv && [ -L "$D20/wt-1/.venv" ] && [ "$(j .ignoredNew)" = 0 ]'
chk "S19c a candidate-created symlink NOT in the manifest stays in the patch, even one pointing at <repo>/P" \
  'grep -q "^+++ b/new-unlisted" "$T/out/s19.patch" && grep -q "^+++ b/pkglink" "$T/out/s19.patch" && grep -q "^+print(2)" "$T/out/s19.patch"'
# A manifest that cannot be read: a failure, never "no links".
mv "$MF" "$MF.bak"; mkdir "$MF"
run_sw diff --worktree "$D20/wt-1" --base HEAD --out "$T/out/s19.patch"
chk "S19d an unreadable link manifest fails the diff (ok:false, no patch left) — never read as no links" \
  '[ "$RC" -eq 1 ] && [ "$(j .ok)" = false ] && j .error | grep -q "manifest" && [ ! -e "$T/out/s19.patch" ]'
rmdir "$MF"; mv "$MF.bak" "$MF"
run_sw cleanup --repo "$BR" --dir "$D20"
# The grants are frozen at the given sha: HEAD moving (the list edited) changes nothing.
printf 'cache\n' > "$BR/.triage-stage-links"; git -C "$BR" commit -qam links-edited
GW2="$T/out/grade-wt2"
git -C "$BR" worktree add -q --detach "$GW2" "$B1"
run_sw link --repo "$BR" --base "$B1" --worktree "$GW2"
chk "S19e link reads the grants at --base, not at a moved HEAD: the base's .venv is linked" \
  '[ "$RC" -eq 0 ] && [ "$(j .base)" = "$B1" ] && [ "$(j ".links | join(\",\")")" = ".venv,cache" ] && [ -L "$GW2/.venv" ]'
git -C "$BR" worktree remove --force "$GW2"
D21="$T/out/stage21"
run_sw create --repo "$BR" --base "$B1" --count 1 --dir "$D21"
chk "S19f create at an older base links the grants committed THERE (HEAD's edited list is not read)" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | join(\",\")")" = ".venv,cache" ]'
run_sw cleanup --repo "$BR" --dir "$D21"
run_sw link --repo "$BR" --base HEAD --worktree "$T/out"
chk "S19g link without a linked worktree, or --check with one, is a usage error" '[ "$RC" -eq 2 ]'
run_sw link --repo "$BR" --base HEAD --check --worktree "$T/out"
chk "S19g …(--check takes no --worktree)" '[ "$RC" -eq 2 ]'
run_sw link --repo "$BR" --base "$BOLD" --check
chk "S19h --check: a path tracked ONLY at the selected base (cache/, untracked now) is refused there; nothing is created" \
  '[ "$RC" -eq 0 ] && [ "$(j .step)" = link-check ] && [ "$(j .base)" = "$BOLD" ] && [ "$(j ".links | join(\",\")")" = .venv ] &&
   [ "$(j ".refused[] | select(.path == \"cache\") | .reason")" = "tracked at the base" ] && [ "$(j "has(\"worktree\")")" = false ]'
run_sw link --repo "$BR" --base HEAD --check
chk "S19h …and linked at a base where it is untracked; --check makes no symlink anywhere" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | join(\",\")")" = cache ] && [ -z "$(find "$T/out" -type l 2>/dev/null | head -n 1)" ]'
# Parents that resolve elsewhere: the repo side (ext -> outside) and the worktree side.
mkdir -p "$T/outside/venv" "$T/elsewhere2" "$BR/tools/venv"
ln -s "$T/outside" "$BR/ext"
printf 'ext/venv\ntools/venv\n' > "$BR/.triage-stage-links"; git -C "$BR" commit -qam parents
GW3="$T/out/grade-wt3"
git -C "$BR" worktree add -q --detach "$GW3" HEAD
ln -s "$T/elsewhere2" "$GW3/tools"
run_sw link --repo "$BR" --base HEAD --worktree "$GW3"
chk "S19i a source path whose parent resolves outside the repo, and a destination whose parent resolves outside the worktree, are refused (nothing made)" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | length")" = 0 ] && [ "$(j ".refused[] | select(.path == \"ext/venv\") | .reason")" = "resolves outside the repo" ] &&
   [ "$(j ".refused[] | select(.path == \"tools/venv\") | .reason")" = "its parent resolves outside the worktree" ] && [ -z "$(ls -A "$T/elsewhere2")" ]'
git -C "$BR" worktree remove --force "$GW3"
# An opt-in file that cannot be READ at the sha (its blob is gone): a failure, never none.
BLOB=$(git -C "$BR" rev-parse HEAD:.triage-stage-links)
OBJ="$BR/.git/objects/${BLOB:0:2}/${BLOB:2}"
mv "$OBJ" "$T/blob.bak"
D22="$T/out/stage22"
run_sw create --repo "$BR" --base HEAD --count 1 --dir "$D22"
chk "S19j an unreadable .triage-stage-links at the sha fails create (exit 1, rolled back) — never 'no links'" \
  '[ "$RC" -eq 1 ] && [ ! -e "$D22" ] && [ "$(wt_count "$BR")" = 1 ] && printf "%s" "$ERR" | grep -q "could not read"'
run_sw link --repo "$BR" --base HEAD --check
chk "S19j …and fails link (exit 1, no JSON)" '[ "$RC" -eq 1 ] && [ -z "$OUT" ]'
mv "$T/blob.bak" "$OBJ"
printf 'data/\n' > "$BR/.triage-leakignore"; git -C "$BR" add .triage-leakignore && git -C "$BR" commit -qm li
BLOB=$(git -C "$BR" rev-parse HEAD:.triage-leakignore); OBJ="$BR/.git/objects/${BLOB:0:2}/${BLOB:2}"
mv "$OBJ" "$T/blob.bak"
run_sw ignored --repo "$BR"; IGN_RC=$RC
run_sw create --repo "$BR" --base HEAD --count 1 --dir "$D22"
chk "S19k an unreadable .triage-leakignore fails ignored (exit 1) and create (exit 1, rolled back) — never 'no exclusions'" \
  '[ "$IGN_RC" -eq 1 ] && [ "$RC" -eq 1 ] && [ ! -e "$D22" ] && [ "$(wt_count "$BR")" = 1 ]'
mv "$T/blob.bak" "$OBJ"
git -C "$BR" rm -q .triage-leakignore && git -C "$BR" commit -qm no-li
# A toolchain BOUND to the source repo: an editable install names <repo>/src.
SP="$BR/.venv/lib/site-packages"
printf '.venv\n' > "$BR/.triage-stage-links"; git -C "$BR" commit -qam venv-only
printf '%s\n../extra\nimport os; os.getcwd()\n# ../../../src\n' "$BR/.venv/lib/extra" > "$SP/self.pth"
ln -s lib "$BR/.venv/lib64"; ln -s /usr/bin/env "$BR/.venv/bin/env"; ln -s ../../tool "$BR/.venv/lib/site-packages/tool"
run_sw link --repo "$BR" --base HEAD --check
chk "S19l self-contained: a .pth naming only the venv itself (absolute or relative), import/# lines, and symlinks inside it or outside the repo — .venv is linked" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | join(\",\")")" = .venv ] && [ "$(j ".refused | length")" = 0 ]'
printf '%s\n' "$BR/src" > "$SP/__editable__.pkg-0.1.pth"
run_sw link --repo "$BR" --base HEAD --check
chk "S19m an editable .pth naming <repo>/src: refused, 'imports the source repo' with the file named" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | length")" = 0 ] && j ".refused[0].reason" | grep -q "^imports the source repo: lib/site-packages/__editable__.pkg-0.1.pth"'
rm -f "$SP/__editable__.pkg-0.1.pth"
mkdir -p "$SP/pkg-0.1.dist-info"
printf '{"url": "file://%s", "dir_info": {}}\n' "$BR" > "$SP/pkg-0.1.dist-info/direct_url.json"
run_sw link --repo "$BR" --base HEAD --check
chk "S19n a NON-editable direct_url.json naming the repo is not bound (the code was copied)" '[ "$(j ".links | join(\",\")")" = .venv ]'
printf '{"url": "file://%s", "dir_info": {"editable": true}}\n' "$BR" > "$SP/pkg-0.1.dist-info/direct_url.json"
run_sw link --repo "$BR" --base HEAD --check
chk "S19n …an editable one is bound (refused)" 'j ".refused[0].reason" | grep -q "^imports the source repo: lib/site-packages/pkg-0.1.dist-info/direct_url.json"'
rm -rf "$SP/pkg-0.1.dist-info"
printf '%s\n.\n' "$BR" > "$SP/pkg.egg-link"
run_sw link --repo "$BR" --base HEAD --check
chk "S19n …and so is an .egg-link naming the repo root" 'j ".refused[0].reason" | grep -q "^imports the source repo: lib/site-packages/pkg.egg-link"'
rm -f "$SP/pkg.egg-link"
printf "MAPPING = {'pkg': '%s/src/pkg'}\n" "$BR" > "$SP/__editable___pkg_0_1_finder.py"
run_sw link --repo "$BR" --base HEAD --check
chk "S19n …and so is setuptools' __editable__ finder module naming <repo>/src/pkg" \
  '[ "$(j ".links | length")" = 0 ] && j ".refused[0].reason" | grep -q "^imports the source repo: lib/site-packages/__editable___pkg_0_1_finder.py names $BR"'
rm -f "$SP/__editable___pkg_0_1_finder.py"
# The retired stage env: a committed .triage-stage-env lifts NOTHING (one notice line).
printf '%s\n' "$BR/src" > "$SP/__editable__.pkg-0.1.pth"
printf 'PYTHONPATH=src\n' > "$BR/.triage-stage-env"
git -C "$BR" add .triage-stage-env && git -C "$BR" commit -qm env
D23="$T/out/stage23"
run_sw create --repo "$BR" --base HEAD --count 1 --dir "$D23"
chk "S19o a committed .triage-stage-env is ignored: the bound venv stays refused, create writes no wt-<i>.env and reports no env, one notice" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | length")" = 0 ] && j ".linkRefused[0].reason" | grep -q "^imports the source repo" && [ ! -e "$D23/wt-1.env" ] &&
   [ "$(j "has(\"env\")")" = false ] && [ "$(printf "%s\n" "$ERR" | grep -c "triage-stage-env at .* is ignored")" = 1 ]'
run_sw cleanup --repo "$BR" --dir "$D23"
run_sw link --repo "$BR" --base HEAD --check
chk "S19o …and link --check alike (no env member, the notice on stderr)" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | length")" = 0 ] && [ "$(j "has(\"env\") or has(\"envRefused\")")" = false ] && printf "%s" "$ERR" | grep -q "the stage env was retired"'
git -C "$BR" rm -q .triage-stage-env && git -C "$BR" commit -qm no-env
rm -f "$SP/__editable__.pkg-0.1.pth"
run_sw link --repo "$BR" --base HEAD --check
chk "S19o …without it, no notice" '[ "$(j ".links | join(\",\")")" = .venv ] && ! printf "%s" "$ERR" | grep -q "triage-stage-env"'
# A RELATIVE .pth entry is resolved against its own directory (as site.py does).
printf '../../../src\n' > "$SP/rel.pth"
run_sw link --repo "$BR" --base HEAD --check
chk "S19p a RELATIVE .pth entry that resolves into the repo (../../../src → <repo>/src) is bound: refused, naming the file and the target" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | length")" = 0 ] && [ "$(j ".refused[0].reason")" = "imports the source repo: lib/site-packages/rel.pth puts $BR/src on the import path — links are only for self-contained toolchains: checks would run the repo'\''s code, not the worktree'\''s" ]'
printf 'sub/../../../../src\n' > "$SP/rel.pth"
run_sw link --repo "$BR" --base HEAD --check
chk "S19p …also through a .. after a missing directory, and to the repo root itself ('../../..')" '[ "$(j ".links | length")" = 0 ]'
printf '../../..\n' > "$SP/rel.pth"
run_sw link --repo "$BR" --base HEAD --check
chk "S19p …(the repo root)" '[ "$(j ".links | length")" = 0 ] && j ".refused[0].reason" | grep -q "puts $BR on the import path"'
rm -f "$SP/rel.pth"
# A symlink INSIDE the linked path that resolves into the repo: a workspace package.
printf 'node_modules/\n' >> "$BR/.gitignore"; mkdir -p "$BR/packages/local" "$BR/node_modules/.bin" "$BR/node_modules/dep"
printf 'module.exports = "source"\n' > "$BR/packages/local/index.js"; printf 'x\n' > "$BR/node_modules/dep/bin.js"
printf '.venv\nnode_modules\n' > "$BR/.triage-stage-links"
git -C "$BR" add .gitignore .triage-stage-links packages && git -C "$BR" commit -qm node
ln -s ../dep/bin.js "$BR/node_modules/.bin/dep"
run_sw link --repo "$BR" --base HEAD --check
chk "S19q node_modules whose symlinks stay inside it (.bin/dep -> ../dep/bin.js) is self-contained: linked" '[ "$(j ".links | join(\",\")")" = ".venv,node_modules" ]'
ln -s ../packages/local "$BR/node_modules/local"
run_sw link --repo "$BR" --base HEAD --check
chk "S19q node_modules/local -> ../packages/local (a workspace package in the repo) is bound: refused, naming the link and its target" \
  '[ "$(j ".links | join(\",\")")" = .venv ] && [ "$(j ".refused[0].path")" = node_modules ] &&
   j ".refused[0].reason" | grep -q "^imports the source repo: local is a symlink to $BR/packages/local, in the repo outside node_modules"'
rm -f "$BR/node_modules/local"; ln -s "$BR/src" "$BR/node_modules/abs"
run_sw link --repo "$BR" --base HEAD --check
chk "S19q …and so is an ABSOLUTE symlink into the repo" 'j ".refused[0].reason" | grep -q "^imports the source repo: abs is a symlink to $BR/src"'
rm -f "$BR/node_modules/abs"; mkdir -p "$BR/node_modules/sub"; ln -s ../../packages/x "$BR/node_modules/sub/dangling"
run_sw link --repo "$BR" --base HEAD --check
chk "S19q …and a DANGLING one that would land in the repo" 'j ".refused[0].reason" | grep -q "^imports the source repo: sub/dangling is a symlink to $BR/packages/x"'
rm -rf "$BR/node_modules/sub"
# The scan is bounded and fails closed: over the bound, a symlink loop, an unwalkable dir.
STAGE_WT_BOUND_SCAN_MAX=1 run_sw link --repo "$BR" --base HEAD --check
chk "S19u over STAGE_WT_BOUND_SCAN_MAX entries the scan stops: refused as could not be scanned, never linked" \
  '[ "$RC" -eq 0 ] && [ "$(j ".links | join(\",\")")" = node_modules ] && [ "$(j ".refused[0].path")" = .venv ] &&
   j ".refused[0].reason" | grep -q "^could not be scanned for references to the source repo: more than 1 symlinks and metadata files under .venv"'
ln -s loop-b "$BR/node_modules/loop-a"; ln -s loop-a "$BR/node_modules/loop-b"
run_sw link --repo "$BR" --base HEAD --check
chk "S19u a symlink loop inside the linked path: refused (could not be scanned)" \
  '[ "$(j ".links | join(\",\")")" = .venv ] && j ".refused[0].reason" | grep -q "^could not be scanned.*symlink loop"'
rm -f "$BR/node_modules/loop-a" "$BR/node_modules/loop-b"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$BR/node_modules/locked/inner"; chmod 000 "$BR/node_modules/locked"
  run_sw link --repo "$BR" --base HEAD --check
  chmod 755 "$BR/node_modules/locked"
  chk "S19u a directory the scan cannot walk (find fails): refused (could not be scanned), never linked" \
    '[ "$(j ".links | join(\",\")")" = .venv ] && j ".refused[0].reason" | grep -q "^could not be scanned.*the scan failed"'
  rm -rf "$BR/node_modules/locked"
fi
rm -rf "$BR/node_modules"; printf '.venv\n' > "$BR/.triage-stage-links"; git -C "$BR" commit -qam venv-again
# .triage-leakignore: negation and root anchoring work as in .gitignore.
NR="$T/neg-repo"
mkrepo "$NR"
printf 'data/\nbuild/\n' > "$NR/.gitignore"; printf 'x\n' > "$NR/x"
printf 'data/*\n!data/keep.json\n/build/\n' > "$NR/.triage-leakignore"
git -C "$NR" add -A && git -C "$NR" commit -qm one
mkdir -p "$NR/data" "$NR/build" "$NR/sub/build"
printf 'a\n' > "$NR/data/a"; printf 'k\n' > "$NR/data/keep.json"; printf 'o\n' > "$NR/build/out"; printf 's\n' > "$NR/sub/build/out"
run_sw ignored --repo "$NR"
chk "S19r leakignore negation (!data/keep.json kept) and root anchoring (/build/ only at the root) behave as in .gitignore" \
  '[ "$RC" -eq 0 ] && printf "%s\n" "$OUT" | grep -q "^data/keep.json	ign:" && printf "%s\n" "$OUT" | grep -q "^sub/build/out	ign:" &&
   ! printf "%s\n" "$OUT" | grep -q "^data/a	" && ! printf "%s\n" "$OUT" | grep -q "^build/out	" && printf "%s" "$ERR" | grep -q "2 ignored path(s) left out"'

echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
