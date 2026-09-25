#!/bin/bash
# Hermetic test suite for scripts/patch-check.sh — the independent grader behind
# workflows/triage-compare.js. Every case runs against scratch git repos under one
# mktemp -d root; nothing here touches this repo or the network.
#
# Covers: applies+pass, applies+fail, a non-applying patch, an empty patch (still
# checked), a new + binary file, an overlay file visible to the check but absent
# from the diffstat and the caller's tree, the caller's tree AND index untouched,
# worktrees (dirs and git bookkeeping) cleaned up, the timeout, a missing patch
# file, JSON shape/order, usage errors (a trailing flag with no value), an overlay
# copy failure (ungradable, never graded), an inherited GIT_DIR/GIT_WORK_TREE,
# a check's grandchildren killed with it (timeout and normal exit), the PARITY_
# env map (export, precedence, unmapped/missing/invalid => exit 2, --print-env)
# and the per-patch cache dir (XDG_CACHE_HOME/TMPDIR/GRANTFORGE_CACHE_DIR).
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

# --- P12: an overlay copy failure is fatal for that patch, never a grade ----------
# overlay/calc.txt/ is a DIRECTORY where the worktree has the file calc.txt, so
# `cp -R` fails (as root too).
OVB="$T/overlay-bad"
mkdir -p "$OVB/calc.txt" "$OVB/hidden"
printf 'x\n' > "$OVB/calc.txt/inner"
printf '#!/bin/bash\necho hidden-ran\n' > "$OVB/hidden/test.sh"
run_pc --repo "$R" --base HEAD --overlay "$OVB" --check 'echo check-ran; true' "$T/fix.patch" "$T/nofix.patch"
chk "P12 overlay copy failed: applies true, rc null, error overlay-failed, and the check never ran" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .applies)" = true ] && [ "$(field 1 .rc)" = null ] && [ "$(field 1 .error)" = overlay-failed ] && ! field 1 .tail | grep -qx check-ran && field 1 .tail | grep -q "overlay copy failed"'
chk "P12b every patch in the run is reported the same way, and its worktree is still cleaned" \
  '[ "$(field 2 .error)" = overlay-failed ] && [ "$(field 2 .rc)" = null ] && [ "$(git -C "$R" worktree list | wc -l | tr -d " ")" -eq 1 ] && [ -z "$(ls -A "$TMPDIR")" ]'
run_pc --repo "$R" --base HEAD --check true "$T/fix.patch"
chk "P12c a normal result carries no error field" '[ "$(field 1 "has(\"error\")")" = false ]'

# --- P13: a trailing value-taking flag is a usage error, never an endless loop ----
OUT=$(perl -e 'alarm shift; exec @ARGV' 20 "$PC" --repo "$R" --base 2>"$T/err"); RC=$?
chk "P13 a trailing --base with no value is exit 2 (needs a value)" '[ "$RC" -eq 2 ] && grep -q -- "--base needs a value" "$T/err"'
OUT=$(perl -e 'alarm shift; exec @ARGV' 20 "$PC" --repo "$R" --base HEAD --check true --timeout 2>"$T/err"); RC=$?
chk "P13b a trailing --timeout too" '[ "$RC" -eq 2 ] && grep -q -- "--timeout needs a value" "$T/err"'

# --- P14: an inherited GIT_DIR/GIT_WORK_TREE does not redirect the grader ---------
DECOY="$T/decoy"
mkdir -p "$DECOY"
git -c init.defaultBranch=main init -q "$DECOY"
printf 'decoy\n' > "$DECOY/calc.txt"
git -C "$DECOY" -c user.email=d@l -c user.name=d add -A && git -C "$DECOY" -c user.email=d@l -c user.name=d commit -qm decoy
DECOY_BEFORE=$({ git -C "$DECOY" status --porcelain; git -C "$DECOY" worktree list; git -C "$DECOY" rev-parse HEAD; })
OUT=$(GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" "$PC" --repo "$R" --base HEAD --check "$CHECK" "$T/fix.patch" 2>"$T/err"); RC=$?
chk "P14 with GIT_DIR/GIT_WORK_TREE of a decoy inherited, the patch is graded against --repo (pass) and the decoy is untouched" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .applies)" = true ] && [ "$(field 1 .rc)" = 0 ] && [ "$({ git -C "$DECOY" status --porcelain; git -C "$DECOY" worktree list; git -C "$DECOY" rev-parse HEAD; })" = "$DECOY_BEFORE" ] && [ "$(git -C "$R" status --porcelain)" = "$STATUS_BEFORE" ]'

# --- P15: a check's grandchildren die with it ------------------------------------
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
GCF="$T/gc.pid"
rm -f "$GCF"
run_pc --repo "$R" --base HEAD --timeout 1 --check "( trap '' TERM; exec sleep 300 ) </dev/null >/dev/null 2>&1 & echo \$! > '$GCF'; sleep 30" "$T/fix.patch"
GC1=$(cat "$GCF" 2>/dev/null)
chk "P15 a timed-out check's TERM-ignoring grandchild is killed before patch-check returns (rc 124)" \
  '[ "$(field 1 .rc)" = 124 ] && [ -n "$GC1" ] && ! alive "$GC1"'
alive "$GC1" && kill -9 "$GC1" 2>/dev/null
rm -f "$GCF"
run_pc --repo "$R" --base HEAD --check "sleep 300 </dev/null >/dev/null 2>&1 & echo \$! > '$GCF'; grep -qx fixed calc.txt" "$T/fix.patch"
GC2=$(cat "$GCF" 2>/dev/null)
chk "P15b a background process left by a check that exited normally is killed too (rc 0 kept)" \
  '[ "$(field 1 .rc)" = 0 ] && [ -n "$GC2" ] && ! alive "$GC2" && [ "$(git -C "$R" worktree list | wc -l | tr -d " ")" -eq 1 ]'
alive "$GC2" && kill -9 "$GC2" 2>/dev/null

# --- P16: the PARITY_ env map — tools reach the check only as mapped variables ----
EM="$T/envs.json"
printf '{"PARITY_PY":"/opt/tools/it'"'"'s py","PARITY_SH":"/bin/sh"}\n' > "$EM"
SEEN="$T/seen.txt"
rm -f "$SEEN"
run_pc --repo "$R" --base HEAD --env-map "$EM" --check "printf '%s|%s\n' \"\$PARITY_PY\" \"\${PARITY_SH}\" > '$SEEN'; \"\$PARITY_SH\" -c 'grep -qx fixed calc.txt'" "$T/fix.patch"
chk "P16 every PARITY_ variable the check references is exported from --env-map (quotes/spaces intact) and the check passes" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 0 ] && [ "$(cat "$SEEN" 2>/dev/null)" = "/opt/tools/it'"'"'s py|/bin/sh" ]'
printf '{"PARITY_SH":"/bin/sh"}\n' > "$T/envs-sh.json"
rm -f "$SEEN"
OUT=$(PARITY_ENV_MAP="$T/envs-sh.json" "$PC" --repo "$R" --base HEAD --check "echo \"\$PARITY_SH\" > '$SEEN'" "$T/fix.patch" 2>"$T/err"); RC=$?
chk "P16b PARITY_ENV_MAP names the map when --env-map is absent" '[ "$RC" -eq 0 ] && [ "$(cat "$SEEN" 2>/dev/null)" = /bin/sh ]'
rm -f "$SEEN"
OUT=$(PARITY_ENV_MAP="$T/no-such.json" "$PC" --repo "$R" --base HEAD --env-map "$EM" --check "echo \"\$PARITY_SH\" > '$SEEN'" "$T/fix.patch" 2>"$T/err"); RC=$?
chk "P16c --env-map wins over PARITY_ENV_MAP" '[ "$RC" -eq 0 ] && [ "$(cat "$SEEN" 2>/dev/null)" = /bin/sh ]'
rm -f "$SEEN"
run_pc --repo "$R" --base HEAD --env-map "$EM" --check "echo ran > '$SEEN'; \"\$PARITY_PY\" x && \"\$PARITY_NOPE\" y" "$T/fix.patch"
chk "P16d an UNMAPPED PARITY_ variable => exit 2 naming it; nothing ran, nothing printed, no worktree" \
  '[ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q "unmapped PARITY_ variable(s) referenced by the check: PARITY_NOPE" "$T/err" && [ ! -e "$SEEN" ] && [ "$(git -C "$R" worktree list | wc -l | tr -d " ")" -eq 1 ]'
OUT=$(PARITY_ENV_MAP="$T/no-such.json" "$PC" --repo "$R" --base HEAD --check '"$PARITY_SH" -c true' "$T/fix.patch" 2>"$T/err"); RC=$?
chk "P16e a PARITY_ reference with no env map at all => exit 2 naming the variable and the map path" \
  '[ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q "PARITY_SH" "$T/err" && grep -qF "$T/no-such.json" "$T/err"'
printf '{"PARITY_SH":"bin/sh"}\n' > "$T/envs-rel.json"
run_pc --repo "$R" --base HEAD --env-map "$T/envs-rel.json" --check '"$PARITY_SH" -c true' "$T/fix.patch"
chk "P16f an env map with a relative path (or a non-PARITY_ key) is invalid => exit 2" '[ "$RC" -eq 2 ] && [ -z "$OUT" ]'
run_pc --repo "$R" --base HEAD --env-map "$EM" --check '"$PARITY_sh" -c true' "$T/fix.patch"
chk "P16g a \$PARITY_ reference that is not PARITY_[A-Z0-9_]+ (bash would read PARITY_sh) => exit 2" '[ "$RC" -eq 2 ] && grep -q "PARITY_sh" "$T/err"'
OUT=$(PARITY_ENV_MAP="$T/no-such.json" "$PC" --repo "$R" --base HEAD --check 'grep -qx fixed calc.txt' "$T/fix.patch" 2>"$T/err"); RC=$?
chk "P16h a check that references no PARITY_ variable never reads the map (a missing one is fine)" '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 0 ]'
OUT=$("$PC" --print-env --env-map "$EM" --check '"$PARITY_SH" a && ${PARITY_PY} b && "$PARITY_SH" c' 2>"$T/err"); RC=$?
chk "P16i --print-env prints one export line per referenced variable (sorted, shell-quoted), no repo/patch needed" \
  '[ "$RC" -eq 0 ] && [ "$OUT" = "export PARITY_PY='"'"'/opt/tools/it'"'"'\'"'"''"'"'s py'"'"'
export PARITY_SH='"'"'/bin/sh'"'"'" ]'
OUT=$("$PC" --print-env --check 'true' 2>"$T/err"); RC=$?
chk "P16j --print-env with no PARITY_ reference prints nothing, exit 0" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
OUT=$("$PC" --print-env --env-map "$EM" --check '"$PARITY_NOPE"' 2>"$T/err"); RC=$?
chk "P16k --print-env: an unmapped variable is exit 2 naming it" '[ "$RC" -eq 2 ] && grep -q PARITY_NOPE "$T/err"'

# --- P17: cache isolation — every check gets its own cache/temp dir ---------------
CE="$T/cacheenv.txt"
rm -f "$CE"
run_pc --repo "$R" --base HEAD --check "printf '%s|%s|%s|%s\n' \"\$XDG_CACHE_HOME\" \"\$TMPDIR\" \"\$GRANTFORGE_CACHE_DIR\" \"\$PWD\" >> '$CE'; [ -d \"\$XDG_CACHE_HOME\" ] && : > \"\$GRANTFORGE_CACHE_DIR/retraction_watch.csv\"" "$T/fix.patch" "$T/nofix.patch"
C1=$(sed -n 1p "$CE" 2>/dev/null); C2=$(sed -n 2p "$CE" 2>/dev/null)
cache_ok() { # $1 = one line: XDG|TMPDIR|GRANTFORGE|PWD
  local x t g w
  IFS='|' read -r x t g w <<EOF2
$1
EOF2
  [ -n "$x" ] && [ "$x" = "$t" ] && [ "$x" = "$g" ] && [ "$(dirname "$x")" = "$(dirname "$w")" ] && [ "$x" != "$w" ] && [ ! -e "$x" ]
}
chk "P17 XDG_CACHE_HOME, TMPDIR and GRANTFORGE_CACHE_DIR all point at one existing dir beside the grading worktree, and it is removed afterwards" \
  '[ "$(field 1 .rc)" = 0 ] && [ "$(field 2 .rc)" = 0 ] && cache_ok "$C1" && cache_ok "$C2"'
chk "P17b each patch gets its OWN cache dir (never shared across candidates), and nothing is left under TMPDIR" \
  '[ "${C1%%|*}" != "${C2%%|*}" ] && [ -z "$(ls -A "$TMPDIR")" ]'

echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
