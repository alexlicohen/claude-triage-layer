#!/bin/bash
# Hermetic test suite for scripts/patch-check.sh — the independent grader behind
# workflows/triage-compare.js. Every case runs against scratch git repos under one
# mktemp -d root; nothing here touches this repo or the network.
#
# Covers: applies+pass, applies+fail, a non-applying patch, an empty patch (still
# checked), a new + binary file, an overlay file visible to the check but absent
# from the diffstat and the caller's tree, the caller's tree AND index untouched,
# worktrees (dirs and git bookkeeping) cleaned up, the timeout, a missing patch
# file, JSON shape/order, and usage errors.
# shellcheck disable=SC2034  # *_BEFORE/START are read inside chk's eval'd conditions
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PC="$REPO_DIR/scripts/patch-check.sh"

for tool in jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "INCOMPLETE: $tool is required to run this suite." >&2; exit 1; }
done
[ -x "$PC" ] || { echo "INCOMPLETE: $PC is missing or not executable." >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

PASS_COUNT=0
FAIL_COUNT=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
# The grader's own temp dirs go here, so "nothing left behind" is checkable.
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"

chk() {
  if eval "$2"; then echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL: $1"; echo "      rc=$RC out: $(printf '%s' "$OUT" | head -5)"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}

OUT=""; RC=0
run_pc() { OUT=$("$PC" "$@" 2>"$T/err"); RC=$?; }
line() { printf '%s\n' "$OUT" | sed -n "${1}p"; }   # the Nth JSON line
field() { line "$1" | jq -r "$2"; }

# --- fixture repo -------------------------------------------------------------
R="$T/repo"
mkdir -p "$R"
git -c init.defaultBranch=main init -q "$R"
git -C "$R" config user.email pc@localhost
git -C "$R" config user.name pc
printf 'broken\n' > "$R/calc.txt"
printf 'keep\n' > "$R/other.txt"
git -C "$R" add -A && git -C "$R" commit -qm init

mkpatch() { # $1 = out file; stdin = shell run in a scratch clone at HEAD
  local s="$T/scratch.$$.$RANDOM"
  git clone -q "$R" "$s"
  ( cd "$s" && bash )
  git -C "$s" add -A
  git -C "$s" diff --cached --binary HEAD > "$1"
  rm -rf "$s"
}
mkpatch "$T/fix.patch" <<'EOF'
printf 'fixed\n' > calc.txt
EOF
mkpatch "$T/nofix.patch" <<'EOF'
printf 'changed\n' > other.txt
EOF
mkpatch "$T/newbin.patch" <<'EOF'
printf 'fixed\n' > calc.txt
printf '\000\001\002binary' > blob.bin
EOF
# A patch against content the base does not have: cannot apply.
cat > "$T/bad.patch" <<'EOF'
diff --git a/calc.txt b/calc.txt
--- a/calc.txt
+++ b/calc.txt
@@ -1 +1 @@
-this line is not in the base
+fixed
EOF
: > "$T/empty.patch"

# The caller's tree is dirty AND has something staged — both must survive.
printf 'wip\n' > "$R/wip-untracked.txt"
printf 'broken\nlocal edit\n' > "$R/calc.txt"
printf 'staged\n' > "$R/staged.txt" && git -C "$R" add staged.txt
STATUS_BEFORE=$(git -C "$R" status --porcelain)
CACHED_BEFORE=$(git -C "$R" diff --cached)
WTDIFF_BEFORE=$(git -C "$R" diff)
HEAD_BEFORE=$(git -C "$R" rev-parse HEAD)

CHECK='echo check-ran; grep -qx fixed calc.txt'

# --- P1-P5: one run over five patches ----------------------------------------
run_pc --repo "$R" --base HEAD --check "$CHECK" "$T/fix.patch" "$T/nofix.patch" "$T/bad.patch" "$T/empty.patch" "$T/newbin.patch"
chk "P0 exits 0 and prints exactly one valid JSON line per patch, in order" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" -eq 5 ] && printf "%s\n" "$OUT" | jq -e . >/dev/null && [ "$(field 1 .patch)" = "$T/fix.patch" ] && [ "$(field 5 .patch)" = "$T/newbin.patch" ]'
chk "P1 applies + check passes: applies true, rc 0, diffstat, tail has the check output" \
  '[ "$(field 1 .applies)" = true ] && [ "$(field 1 .rc)" = 0 ] && field 1 .diffstat | grep -q "1 file changed" && field 1 .tail | grep -qx check-ran'
chk "P2 applies + check fails: applies true, rc non-zero" \
  '[ "$(field 2 .applies)" = true ] && [ "$(field 2 .rc)" = 1 ]'
chk "P3 a non-applying patch: applies false, rc null, the check never ran" \
  '[ "$(field 3 .applies)" = false ] && [ "$(field 3 .rc)" = null ] && ! field 3 .tail | grep -q check-ran'
chk "P4 an empty patch applies trivially (diffstat empty) and is STILL checked" \
  '[ "$(field 4 .applies)" = true ] && [ "$(field 4 .diffstat)" = "" ] && [ "$(field 4 .rc)" = 1 ] && field 4 .tail | grep -qx check-ran'
chk "P5 a new binary file applies (--binary) and counts in the diffstat" \
  '[ "$(field 5 .applies)" = true ] && [ "$(field 5 .rc)" = 0 ] && field 5 .diffstat | grep -q "2 files changed"'

chk "P6 the caller's working tree, index and HEAD are untouched" \
  '[ "$(git -C "$R" status --porcelain)" = "$STATUS_BEFORE" ] && [ "$(git -C "$R" diff --cached)" = "$CACHED_BEFORE" ] && [ "$(git -C "$R" diff)" = "$WTDIFF_BEFORE" ] && [ "$(git -C "$R" rev-parse HEAD)" = "$HEAD_BEFORE" ] && [ -z "$(git -C "$R" stash list)" ]'
chk "P7 every worktree is gone: git lists only the main one, no bookkeeping, no temp dirs left" \
  '[ "$(git -C "$R" worktree list | wc -l | tr -d " ")" -eq 1 ] && [ -z "$(ls -A "$R/.git/worktrees" 2>/dev/null)" ] && [ -z "$(ls -A "$TMPDIR")" ]'

# --- P8: the overlay ------------------------------------------------------------
OV="$T/overlay"
mkdir -p "$OV/hidden"
printf '#!/bin/bash\ngrep -qx fixed calc.txt && echo hidden-test-ok\n' > "$OV/hidden/test.sh"
run_pc --repo "$R" --base HEAD --overlay "$OV" --check 'bash hidden/test.sh' "$T/fix.patch"
chk "P8 an overlay file is visible to the check" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 0 ] && field 1 .tail | grep -qx hidden-test-ok'
chk "P8b the overlay never enters the diffstat nor the caller's tree" \
  'field 1 .diffstat | grep -q "^1 file changed" && [ ! -e "$R/hidden" ] && [ "$(git -C "$R" status --porcelain)" = "$STATUS_BEFORE" ]'

# --- P9: timeout --------------------------------------------------------------
START=$SECONDS
run_pc --repo "$R" --base HEAD --timeout 1 --check 'sleep 30' "$T/fix.patch"
chk "P9 a check over --timeout is killed and reported as rc 124" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 124 ] && field 1 .tail | grep -q "timed out" && [ $((SECONDS - START)) -lt 15 ]'
chk "P9b the timed-out run still cleans its worktree" \
  '[ "$(git -C "$R" worktree list | wc -l | tr -d " ")" -eq 1 ] && [ -z "$(ls -A "$TMPDIR")" ]'

# --- P10: a missing patch file ------------------------------------------------
run_pc --repo "$R" --base HEAD --check true "$T/no-such.patch"
chk "P10 a missing patch file is applies false with the reason in tail" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .applies)" = false ] && [ "$(field 1 .rc)" = null ] && field 1 .tail | grep -q "not found"'

# --- P11: usage errors --------------------------------------------------------
run_pc --repo "$R" --base no-such-rev --check true "$T/fix.patch"
chk "P11 an unknown --base is a usage error (exit 2), nothing printed" '[ "$RC" -eq 2 ] && [ -z "$OUT" ]'
run_pc --repo "$R" --base HEAD "$T/fix.patch"
chk "P11b a missing --check is a usage error (exit 2)" '[ "$RC" -eq 2 ]'
run_pc --repo "$T/tmp" --base HEAD --check true "$T/fix.patch"
chk "P11c a non-repo --repo is a usage error (exit 2)" '[ "$RC" -eq 2 ]'
chk "P11d usage errors leave no worktree behind" '[ "$(git -C "$R" worktree list | wc -l | tr -d " ")" -eq 1 ]'

echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
