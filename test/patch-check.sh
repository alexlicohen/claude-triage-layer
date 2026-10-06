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
# and the per-patch cache dir (XDG_CACHE_HOME/TMPDIR/GRANTFORGE_CACHE_DIR), and
# the stage links of HEAD:.triage-stage-links (via stage-worktree.sh link): a
# venv-dependent check exits 127 without them and passes with them, refusals
# unchanged, a patch occupying a linked path rejected (never written through the
# link), an overlay holding one ungradable, a failed link step = harness, and a
# missing stage-worktree.sh = exit 2; a toolchain bound to the source repo (a real
# editable venv) refused with no override — a patch that DELETES the package never
# passes off the repo's copy — while a self-contained venv is linked and the check
# imports the grading worktree's code; repeated --check: graded as ONE `bash -c 'A' &&
# bash -c 'B'` run in one process group (a background process check 1 starts serves
# check 2), checks run one by one only in --baseline-on's classification pass (which
# check, kept only when the rerun reproduces the rc) comparing the failing check with
# THE SAME check on the base; and source-bound import settings (PYTHONPATH & co.)
# never reaching a check.
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
fieldc() { line "$1" | jq -c "$2"; }   # compact JSON (arrays)

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
chk "P10b ...and it is a HARNESS fault (error:\"harness\", ungradable), never the candidate's fail" '[ "$(field 1 .error)" = harness ]'

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

# --- P18: --summary — ONE machine line, tails in files, changed paths (H5, M10) ---
TD="$T/tails"
run_pc --repo "$R" --base HEAD --check 'echo CANDIDATE-OUTPUT-rc0 PATCHCHECK-fake; grep -qx fixed calc.txt' --summary --tail-dir "$TD" \
  "$T/fix.patch" "$T/nofix.patch" "$T/bad.patch" "$T/missing.patch"
SJ=${OUT#PATCHCHECK }
chk "P18 --summary prints exactly ONE line, 'PATCHCHECK {json}', with the resolved base sha" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 1 ] && case "$OUT" in "PATCHCHECK {"*) true ;; *) false ;; esac &&
   [ "$(printf "%s" "$SJ" | jq -r .base)" = "$(git -C "$R" rev-parse HEAD)" ]'
chk "P18b one result per patch, in order: pass / fail / not applying / harness" \
  '[ "$(printf "%s" "$SJ" | jq -r "[.results[] | \"\(.applies):\(.rc):\(.error // \"-\")\"] | join(\",\")")" = "true:0:-,true:1:-,false:null:-,false:null:harness" ]'
chk "P18c candidate-written check output is NOT in the line; it is in the tail file named by tailFile" \
  '! printf "%s" "$OUT" | grep -q CANDIDATE-OUTPUT && grep -q CANDIDATE-OUTPUT "$(printf "%s" "$SJ" | jq -r ".results[0].tailFile")" && [ "$(printf "%s" "$SJ" | jq -r ".results[0].tailFile")" = "$TD/1.tail" ]'
chk "P18d files = the paths each applied patch changes (overlay excluded), filesTruncated false" \
  '[ "$(printf "%s" "$SJ" | jq -r ".results[0].files | join(\",\")")" = calc.txt ] && [ "$(printf "%s" "$SJ" | jq -r ".results[1].files | join(\",\")")" = other.txt ] && [ "$(printf "%s" "$SJ" | jq -r ".results[0].filesTruncated")" = false ]'
run_pc --repo "$R" --base HEAD --check true --summary "$T/fix.patch"
chk "P18e --summary without --tail-dir is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

# --- P19: stage links — the grading worktree gets the candidates' links ---------
K="$T/linkrepo"
mkdir -p "$K"
git -c init.defaultBranch=main init -q "$K"
git -C "$K" config user.email pc@localhost
git -C "$K" config user.name pc
printf '.venv/\nlocal.cfg\n' > "$K/.gitignore"
printf 'broken\n' > "$K/calc.txt"
git -C "$K" add -A && git -C "$K" commit -qm init
# The gitignored toolchain the checks need, and a gitignored config FILE.
mkdir -p "$K/.venv/bin"
printf '#!/bin/sh\necho ok\n' > "$K/.venv/bin/tool"; chmod +x "$K/.venv/bin/tool"
printf 'real\n' > "$K/local.cfg"
TOOL_SUM=$(cksum < "$K/.venv/bin/tool")
KCHECK='.venv/bin/tool && grep -qx fixed calc.txt'
kpatch() { # $1 = out file; stdin = shell run in a scratch clone of K at HEAD
  local s="$T/kscratch.$$.$RANDOM"
  git clone -q "$K" "$s"
  ( cd "$s" && bash )
  git -C "$s" add -A
  git -C "$s" diff --cached --binary HEAD > "$1"
  rm -rf "$s"
}
kpatch "$T/kfix.patch" <<'KP'
printf 'fixed\n' > calc.txt
KP
# A candidate patch that brings its OWN .venv (a fake tool printing ok + an extra file).
kpatch "$T/kvenv.patch" <<'KP'
printf 'fixed\n' > calc.txt
mkdir -p .venv/bin
printf '#!/bin/sh\necho ok\n' > .venv/bin/tool; chmod +x .venv/bin/tool
printf 'evil\n' > .venv/bin/evil
git add -f .venv/bin/tool .venv/bin/evil
KP
# A patch that un-ignores the linked path: the link must still not be counted.
kpatch "$T/kunign.patch" <<'KP'
printf 'fixed\n' > calc.txt
printf 'local.cfg\n' > .gitignore
KP
k_untouched() { [ "$(cksum < "$K/.venv/bin/tool")" = "$TOOL_SUM" ] && [ ! -e "$K/.venv/bin/evil" ] && [ "$(cat "$K/local.cfg")" = real ] && [ -d "$K/.venv" ] && [ ! -L "$K/.venv" ]; }
k_clean() { [ "$(git -C "$K" worktree list | wc -l | tr -d ' ')" = 1 ] && [ -z "$(ls -A "$TMPDIR")" ]; }

run_pc --repo "$K" --base HEAD --check "$KCHECK" "$T/kfix.patch"
chk "P19a without .triage-stage-links the grading worktree has no .venv: the check exits 127 (graded invalid upstream)" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .applies)" = true ] && [ "$(field 1 .rc)" = 127 ]'

printf '# toolchain\n.venv/\nlocal.cfg\ncalc.txt\nmissing\n' > "$K/.triage-stage-links"
git -C "$K" add .triage-stage-links && git -C "$K" commit -qm links
run_pc --repo "$K" --base HEAD --check "$KCHECK" "$T/kfix.patch"
chk "P19b with .triage-stage-links the SAME patch passes: the grading worktree gets the .venv link" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .applies)" = true ] && [ "$(field 1 .rc)" = 0 ] && [ "$(field 1 .diffstat)" = "1 file changed, 1 insertion(+), 1 deletion(-)" ]'
chk "P19c refusals are unchanged and not fatal: a tracked and a missing entry are NOT linked, named in the tail" \
  'field 1 .tail | grep -q "NOT linked" && field 1 .tail | grep -q "calc.txt (tracked in the repo)" && field 1 .tail | grep -q "missing (does not exist in the repo)"'
chk "P19d grading never follows a link: the repo's toolchain and config are intact, no worktree or temp dir is left" 'k_untouched && k_clean'

run_pc --repo "$K" --base HEAD --check "$KCHECK" "$T/kvenv.patch" "$T/kfix.patch"
chk "P19e a patch that occupies a linked path (its own .venv) is REJECTED, never graded with the toolchain it brought" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .applies)" = false ] && [ "$(field 1 .rc)" = null ] && [ "$(field 1 .error)" = null ] && field 1 .tail | grep -q "REJECTED" &&
   [ "$(field 2 .rc)" = 0 ]'
chk "P19f ...and nothing it carried reached the repo through the link (.venv/bin/tool unchanged, no .venv/bin/evil)" 'k_untouched && k_clean'

TDK="$T/ktails"
run_pc --repo "$K" --base HEAD --check "$KCHECK" --summary --tail-dir "$TDK" "$T/kunign.patch"
KJ=${OUT#PATCHCHECK }
chk "P19g a patch that un-ignores the linked path still passes, and the link is not in its files or diffstat" \
  '[ "$(printf "%s" "$KJ" | jq -r ".results[0].rc")" = 0 ] && [ "$(printf "%s" "$KJ" | jq -r ".results[0].files | join(\",\")")" = ".gitignore,calc.txt" ] &&
   printf "%s" "$KJ" | jq -r ".results[0].diffstat" | grep -q "^2 files changed"'

KOV="$T/koverlay"
mkdir -p "$KOV"; printf 'overlay\n' > "$KOV/local.cfg"
run_pc --repo "$K" --base HEAD --check "$KCHECK" --overlay "$KOV" "$T/kfix.patch"
chk "P19h an overlay holding a stage-linked path is overlay-failed (check not run) and is never copied through the link" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .error)" = overlay-failed ] && [ "$(field 1 .rc)" = null ] && field 1 .tail | grep -q "stage-linked path" && k_untouched && k_clean'
KOV2="$T/koverlay2"
mkdir -p "$KOV2"; printf 'hidden\n' > "$KOV2/hidden_test.txt"
run_pc --repo "$K" --base HEAD --check "$KCHECK && [ -f hidden_test.txt ]" --overlay "$KOV2" "$T/kfix.patch"
chk "P19i an ordinary overlay still works alongside the links" '[ "$(field 1 .rc)" = 0 ] && [ "$(field 1 .error)" = null ] && k_untouched'

# A missing owner: exit 2 before anything runs. A failing / garbled owner: harness.
mkdir -p "$T/lone" "$T/stub1" "$T/stub2"
cp "$PC" "$T/lone/patch-check.sh"; cp "$PC" "$T/stub1/patch-check.sh"; cp "$PC" "$T/stub2/patch-check.sh"
printf '#!/bin/sh\necho "stub link failure" >&2\nexit 1\n' > "$T/stub1/stage-worktree.sh"
printf '#!/bin/sh\necho "not json"\n' > "$T/stub2/stage-worktree.sh"
chmod +x "$T/stub1/stage-worktree.sh" "$T/stub2/stage-worktree.sh"
OUT=$("$T/lone/patch-check.sh" --repo "$K" --base HEAD --check true "$T/kfix.patch" 2>"$T/err"); RC=$?
chk "P19j stage-worktree.sh missing beside patch-check.sh is exit 2 naming it, nothing graded" \
  '[ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q "stage-worktree.sh is missing" "$T/err"'
OUT=$("$T/stub1/patch-check.sh" --repo "$K" --base HEAD --check true "$T/kfix.patch" 2>"$T/err"); RC=$?
chk "P19k a link step that fails is error harness (ungradable), never a graded pass" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .error)" = harness ] && [ "$(field 1 .rc)" = null ] && field 1 .tail | grep -q "stub link failure" && k_clean'
OUT=$("$T/stub2/patch-check.sh" --repo "$K" --base HEAD --check true "$T/kfix.patch" 2>"$T/err"); RC=$?
chk "P19l a link step that prints no link result is error harness too" '[ "$(field 1 .error)" = harness ] && k_clean'

# Documented, not prevented: what the CHECK writes through a link lands in the repo
# (the bake-off's leakcheck, run after grading, sees it).
run_pc --repo "$K" --base HEAD --check 'printf x > .venv/written' "$T/kfix.patch"
chk "P19m a check's own write through the link lands in the real repo (leakcheck's job)" '[ "$(field 1 .rc)" = 0 ] && [ -f "$K/.venv/written" ]'

# --- P20: overlay aliases, a strict link relay, frozen grants, the stage env, the
# pristine-base rc (--baseline-on), a toolchain bound to the source repo ----------
# A patch whose own symlink would carry the overlay copy out of the worktree: into the
# real repo (absolute), into a linked path (relative), or under a symlinked directory.
kpatch "$T/kalias.patch" <<KP
printf 'fixed\n' > calc.txt
ln -s "$K/local.cfg" hidden_test.txt
ln -s .venv/config hidden_rel.txt
ln -s "$T/kalias-out" tests
KP
mkdir -p "$T/kalias-out"
for ov in hidden_test.txt hidden_rel.txt tests/hidden.py; do
  KOV3="$T/kov-$(printf '%s' "$ov" | tr '/.' '__')"
  mkdir -p "$KOV3/$(dirname "$ov")"; printf 'HIDDEN\n' > "$KOV3/$ov"
  run_pc --repo "$K" --base HEAD --check "$KCHECK" --overlay "$KOV3" "$T/kalias.patch"
  chk "P20a an overlay entry ($ov) that would be copied through a symlink the PATCH made is overlay-failed, never copied" \
    '[ "$RC" -eq 0 ] && [ "$(field 1 .error)" = overlay-failed ] && [ "$(field 1 .rc)" = null ] && field 1 .tail | grep -q "symlink in the patched worktree" &&
     k_untouched && [ ! -e "$K/.venv/config" ] && [ -z "$(ls -A "$T/kalias-out")" ] && k_clean'
done
# The link relay is strict: no output, two objects, or a malformed member = harness.
for stub in 'exit 0' 'echo "{\"step\":\"link\",\"links\":[],\"refused\":[],\"env\":null}"; echo "{\"step\":\"link\",\"links\":[],\"refused\":[],\"env\":null}"' \
            'echo "{\"step\":\"link\",\"links\":[1],\"refused\":[],\"env\":null}"' 'echo "{\"step\":\"link\",\"links\":[\"../up\"],\"refused\":[],\"env\":null}"' \
            'echo "{\"step\":\"link\",\"links\":[],\"refused\":[],\"env\":{\"LD_PRELOAD\":\"/x\"}}"'; do
  mkdir -p "$T/stub3"; cp "$PC" "$T/stub3/patch-check.sh"
  printf '#!/bin/sh\n%s\n' "$stub" > "$T/stub3/stage-worktree.sh"; chmod +x "$T/stub3/stage-worktree.sh"
  OUT=$("$T/stub3/patch-check.sh" --repo "$K" --base HEAD --check true "$T/kfix.patch" 2>"$T/err"); RC=$?
  chk "P20b a link step printing $(printf '%s' "$stub" | cut -c1-60)… is error harness — never 'no links'" \
    '[ "$RC" -eq 0 ] && [ "$(field 1 .error)" = harness ] && [ "$(field 1 .rc)" = null ] && k_clean'
done
# Frozen grants: grading reads .triage-stage-links at the base sha, not a moved HEAD.
KB=$(git -C "$K" rev-parse HEAD)
printf 'local.cfg\n' > "$K/.triage-stage-links"; git -C "$K" commit -qam links-edited
run_pc --repo "$K" --base "$KB" --check "$KCHECK" "$T/kfix.patch"
chk "P20c grading at the bake-off's base sha links the base's .venv although HEAD's list dropped it" '[ "$(field 1 .rc)" = 0 ] && k_untouched'
run_pc --repo "$K" --base HEAD --check "$KCHECK" "$T/kfix.patch"
chk "P20c …while grading at the new HEAD has no .venv (127)" '[ "$(field 1 .rc)" = 127 ]'
# The retired stage env: a committed .triage-stage-env exports nothing (a notice in the tail).
printf '.venv\n' > "$K/.triage-stage-links"; printf 'PYTHONPATH=lib:.\n' > "$K/.triage-stage-env"
git -C "$K" add -A .triage-stage-links .triage-stage-env && git -C "$K" commit -qm env
run_pc --repo "$K" --base HEAD --check '[ -z "${PYTHONPATH:-}" ] && .venv/bin/tool' "$T/kfix.patch"
chk "P20d a committed .triage-stage-env is ignored: no PYTHONPATH reaches the check, the venv is still linked, the tail says why" \
  '[ "$(field 1 .rc)" = 0 ] && field 1 .tail | grep -q "triage-stage-env at .* is ignored" && k_untouched'
git -C "$K" rm -q .triage-stage-env && git -C "$K" commit -qm no-env
# --baseline-on: a 126/127 is compared with the same check on the pristine base.
printf '#!/bin/sh\nexit 0\n' > "$K/run.sh"; chmod +x "$K/run.sh"; git -C "$K" add run.sh && git -C "$K" commit -qm run
kpatch "$T/kdelrun.patch" <<'KP'
git rm -q run.sh
KP
kpatch "$T/knoexec.patch" <<'KP'
chmod -x run.sh
KP
run_pc --repo "$K" --base HEAD --check './run.sh' --baseline-on 126,127 "$T/kdelrun.patch" "$T/knoexec.patch" "$T/kfix.patch"
chk "P20e a patch that deletes / un-chmods the script the check runs exits 127 / 126 — baseRc 0: the base runs it" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 127 ] && [ "$(field 1 .baseRc)" = 0 ] && [ "$(field 2 .rc)" = 126 ] && [ "$(field 2 .baseRc)" = 0 ] &&
   field 1 .tail | grep -q "pristine base exited 0" && k_clean'
chk "P20e …a patch whose rc is not in the list carries no baseRc" '[ "$(field 3 .rc)" = 0 ] && [ "$(field 3 "has(\"baseRc\")")" = false ]'
run_pc --repo "$K" --base HEAD --check '.missing/bin/tool' --baseline-on 126,127 --summary --tail-dir "$T/ktails2" "$T/kfix.patch"
chk "P20e a toolchain missing everywhere: rc 127 and baseRc 127 (the base fails the same way)" \
  '[ "$(printf "%s" "${OUT#PATCHCHECK }" | jq -c "[.results[0].rc, .results[0].baseRc]")" = "[127,127]" ]'
run_pc --repo "$K" --base HEAD --check './run.sh' "$T/kdelrun.patch"
chk "P20e without --baseline-on there is no baseRc" '[ "$(field 1 .rc)" = 127 ] && [ "$(field 1 "has(\"baseRc\")")" = false ]'
run_pc --repo "$K" --base HEAD --check true --baseline-on 'x' "$T/kfix.patch"
chk "P20e a malformed --baseline-on is exit 2" '[ "$RC" -eq 2 ]'

# A toolchain BOUND to the source repo — a real Python venv whose editable .pth names
# <repo>/src. Linked as-is, the grading worktree would import the REPO's code.
PYR="$T/pyrepo"
mkdir -p "$PYR/src/pkg" "$PYR/flat"
git -c init.defaultBranch=main init -q "$PYR"
git -C "$PYR" config user.email pc@localhost; git -C "$PYR" config user.name pc
printf '.venv/\n' > "$PYR/.gitignore"; printf 'WHO = "source"\n' > "$PYR/src/pkg/__init__.py"; printf '.venv\n' > "$PYR/.triage-stage-links"
printf 'WHO = "source"\n' > "$PYR/flat/__init__.py"
git -C "$PYR" add -A && git -C "$PYR" commit -qm init
PYOK=0
if command -v python3 >/dev/null 2>&1 && python3 -m venv --without-pip "$PYR/.venv" >/dev/null 2>&1; then
  SITE=$("$PYR/.venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null)
  [ -d "$SITE" ] && printf '%s\n' "$PYR/src" > "$SITE/__editable__.pkg-0.1.pth" &&
    [ "$(cd "$T" && "$PYR/.venv/bin/python" -B -c 'import pkg; print(pkg.WHO)')" = source ] && PYOK=1
fi
chk "P20f fixture: a real venv (python3 -m venv) whose editable .pth makes 'import pkg' load <repo>/src" '[ "$PYOK" -eq 1 ]'
if [ "$PYOK" -eq 1 ]; then
  PYSUM=$(cksum < "$PYR/src/pkg/__init__.py")
  PYCHECK='.venv/bin/python -B -c "import pkg, sys; print(\"imported\", pkg.WHO, pkg.__file__); sys.exit(0 if pkg.WHO == \"worktree\" else 3)"'
  ( s="$T/pyscratch"; git clone -q "$PYR" "$s"; printf 'WHO = "worktree"\n' > "$s/src/pkg/__init__.py"; printf 'WHO = "worktree"\n' > "$s/flat/__init__.py"
    git -C "$s" diff --binary > "$T/pyfix.patch"; git -C "$s" checkout -q -- .; git -C "$s" rm -q src/pkg/__init__.py; git -C "$s" diff --cached --binary > "$T/pydel.patch"; rm -rf "$s" )
  # Why it is refused: linked by hand, the venv imports the SOURCE repo's package.
  PW="$T/pyhand"
  git -C "$PYR" worktree add -q --detach "$PW" HEAD && git -C "$PW" apply "$T/pyfix.patch" && ln -s "$PYR/.venv" "$PW/.venv"
  HAND=$(cd "$PW" && bash -c "$PYCHECK" 2>&1); HAND_RC=$?
  git -C "$PYR" worktree remove --force "$PW"
  chk "P20f (the bug) a linked editable venv imports the source repo's code, not the patched worktree's" \
    '[ "$HAND_RC" -eq 3 ] && printf "%s" "$HAND" | grep -q "imported source $PYR/src/pkg/__init__.py"'
  run_pc --repo "$PYR" --base HEAD --check "$PYCHECK" --baseline-on 126,127 "$T/pyfix.patch"
  chk "P20f patch-check refuses the bound venv (imports the source repo): the check exits 127 on the patch AND the base" \
    '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 127 ] && [ "$(field 1 .baseRc)" = 127 ] && field 1 .tail | grep -q "imports the source repo"'
  # The deletion case: a patch that DELETES the package. Linked by hand, the venv still
  # imports the repo's copy, so `import pkg` "passes"; no environment can undo that.
  DELCHECK='.venv/bin/python -B -c "import pkg"'
  PW="$T/pydelhand"
  git -C "$PYR" worktree add -q --detach "$PW" HEAD && git -C "$PW" apply "$T/pydel.patch" && ln -s "$PYR/.venv" "$PW/.venv"
  ( cd "$PW" && PYTHONPATH="$PW/src" bash -c "$DELCHECK" ) >/dev/null 2>&1; HAND_RC=$?
  git -C "$PYR" worktree remove --force "$PW"
  chk "P20h (the bug) a linked editable venv imports the deleted package from the source repo — even with PYTHONPATH=<worktree>/src first" '[ "$HAND_RC" -eq 0 ]'
  printf 'PYTHONPATH=src\n' > "$PYR/.triage-stage-env"; git -C "$PYR" add .triage-stage-env && git -C "$PYR" commit -qm env
  run_pc --repo "$PYR" --base HEAD --check "$DELCHECK" --baseline-on 126,127 "$T/pydel.patch"
  chk "P20h patch-check refuses the bound venv even with a committed .triage-stage-env: the deletion exits 127 on the patch AND the base, never 0" \
    '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 127 ] && [ "$(field 1 .baseRc)" = 127 ] && field 1 .tail | grep -q "imports the source repo" &&
     field 1 .tail | grep -q "triage-stage-env at .* is ignored"'
  git -C "$PYR" rm -q .triage-stage-env && git -C "$PYR" commit -qm no-env
  # A SELF-CONTAINED venv (no reference to the repo): the project is imported from the
  # check's cwd, the grading worktree's root — linked, and the worktree's code runs.
  rm -f "$SITE/__editable__.pkg-0.1.pth"
  FLATCHECK='.venv/bin/python -B -c "import flat, sys; print(\"imported\", flat.WHO, flat.__file__); sys.exit(0 if flat.WHO == \"worktree\" else 3)"'
  run_pc --repo "$PYR" --base HEAD --check "$FLATCHECK" "$T/pyfix.patch"
  chk "P20g a self-contained venv is linked and the check, run from the worktree root, imports the GRADING WORKTREE's patched code" \
    '[ "$(field 1 .rc)" = 0 ] && field 1 .tail | grep -q "imported worktree $TMPDIR/patch-check\.[^/]*/wt-1/flat/__init__.py" && ! field 1 .tail | grep -q "NOT linked"'
  chk "P20g …the source repo's packages are untouched and no worktree or temp dir is left" \
    '[ "$(cksum < "$PYR/src/pkg/__init__.py")" = "$PYSUM" ] && grep -q source "$PYR/flat/__init__.py" && [ -z "$(ls -A "$TMPDIR")" ] && [ "$(git -C "$PYR" worktree list | wc -l | tr -d " ")" = 1 ]'
  # The SAME self-contained venv with an INHERITED PYTHONPATH=<repo>/src: by hand, a
  # patch that deletes the package still imports the source repo's copy; patch-check
  # clears PYTHONPATH, so the deletion is seen.
  PKGCHECK='.venv/bin/python -B -c "import pkg; print(\"imported\", pkg.__file__)"'
  PW="$T/pyenvhand"
  git -C "$PYR" worktree add -q --detach "$PW" HEAD && git -C "$PW" apply "$T/pydel.patch" && ln -s "$PYR/.venv" "$PW/.venv"
  ( cd "$PW" && PYTHONPATH="$PYR/src" bash -c "$PKGCHECK" ) >/dev/null 2>&1; HAND_RC=$?
  git -C "$PYR" worktree remove --force "$PW"
  chk "P23b (the bug) a self-contained venv with an inherited PYTHONPATH=<repo>/src imports a package the patch deleted" '[ "$HAND_RC" -eq 0 ]'
  OUT=$(PYTHONPATH="$PYR/src" "$PC" --repo "$PYR" --base HEAD --check "$PKGCHECK" "$T/pydel.patch" 2>"$T/err"); RC=$?
  chk "P23b patch-check with PYTHONPATH=<repo>/src inherited: the deleted package is NOT imported (the check fails), never masked by the source repo" \
    '[ "$RC" -eq 0 ] && [ "$(field 1 .applies)" = true ] && [ "$(field 1 .rc)" != 0 ] && [ "$(field 1 .rc)" != null ] && ! field 1 .tail | grep -q "imported" && field 1 .tail | grep -q "No module named"'
fi

# --- P21: repeated --check — && semantics, per-check rcs, and the pristine base
# compared check by check (the base runs EVERY check, past a failure) -------------
run_pc --repo "$K" --base HEAD --check 'grep -q fixed calc.txt' --check '.missing/bin/tool' --baseline-on 126,127 "$T/kfix.patch"
chk "P21a two checks: the patch passes check 1 and gets 127 on check 2 → rc 127, rcs [0,127], failedCheck 1" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 127 ] && [ "$(fieldc 1 .rcs)" = "[0,127]" ] && [ "$(field 1 .failedCheck)" = 1 ]'
chk "P21a …the base FAILS check 1 (the bug the patch fixed) yet still runs check 2: baseRcs [1,127], baseRc 127 (that same check), named in the tail" \
  '[ "$(fieldc 1 .baseRcs)" = "[1,127]" ] && [ "$(field 1 .baseRc)" = 127 ] && field 1 .tail | grep -q "same check (check 2 of 2) on the pristine base exited 127"'
run_pc --repo "$K" --base HEAD --check 'grep -q fixed calc.txt' --check './run.sh' --baseline-on 126,127 "$T/kdelrun.patch"
chk "P21b a patch that fails check 1 (rc 1): the graded run is ONE process, so which check failed is unknown (rcs null, failedCheck null) and no baseRc is asked" \
  '[ "$(field 1 .rc)" = 1 ] && [ "$(fieldc 1 "[.rcs, .failedCheck]")" = "[null,null]" ] && [ "$(field 1 "has(\"baseRc\")")" = false ]'
kpatch "$T/kfixdel.patch" <<'KP'
printf 'fixed\n' > calc.txt
git rm -q run.sh
KP
run_pc --repo "$K" --base HEAD --check 'grep -q fixed calc.txt' --check './run.sh' --baseline-on 126,127 --summary --tail-dir "$T/p21" "$T/kfixdel.patch"
chk "P21b …a patch that fixes check 1 and deletes check 2's script: rc 127 at check 2, baseRc 0 there (baseRcs [1,0])" \
  '[ "$(printf "%s" "${OUT#PATCHCHECK }" | jq -c ".results[0] | [.rc, .rcs, .failedCheck, .baseRc, .baseRcs]")" = "[127,[0,127],1,0,[1,0]]" ]'
run_pc --repo "$K" --base HEAD --check 'true' --check 'grep -q fixed calc.txt' --check 'true' "$T/kfix.patch" "$T/kdelrun.patch"
chk "P21c all checks pass → rc 0, rcs every check, failedCheck null; a failure (no --baseline-on) → its rc, rcs/failedCheck null (never re-run check by check)" \
  '[ "$(fieldc 1 "[.rc, .rcs, .failedCheck]")" = "[0,[0,0,0],null]" ] && [ "$(fieldc 2 "[.rc, .rcs, .failedCheck]")" = "[1,null,null]" ] && ! field 2 .tail | grep -q "check by check"'
run_pc --repo "$K" --base HEAD --check 'true' --check '' "$T/kfix.patch"
chk "P21d an empty --check is a usage error (exit 2)" '[ "$RC" -eq 2 ]'
run_pc --repo "$K" --base HEAD --check 'false' "$T/nonexistent.patch"
chk "P21e a result whose check never ran carries rcs [] and failedCheck null" '[ "$(fieldc 1 "[.rcs, .failedCheck]")" = "[[],null]" ]'
run_pc --repo "$K" --base HEAD --check 'false' --check 'true || true' --check "[ \"\$(printf '%s' \"it's\")\" = \"it's\" ]" "$T/kfix.patch"
OUT1=$OUT
run_pc --repo "$K" --base HEAD --check 'true' --check "[ \"\$(printf '%s' \"it's\")\" = \"it's\" ]" "$T/kfix.patch"
chk "P21f the graded run is bash -c 'A' && bash -c 'B': a later check's own || never masks an earlier failure, and a check holding single quotes runs intact" \
  '[ "$(printf "%s" "$OUT1" | jq -r .rc)" = 1 ] && [ "$(field 1 .rc)" = 0 ] && [ "$(fieldc 1 .rcs)" = "[0,0]" ]'

# --- P22: the GRADED run is one process group across checks (as before Wave 23); the
# per-check runs exist only in the --baseline-on classification pass --------------
BGF="$T/bg.pid"; rm -f "$BGF"
run_pc --repo "$K" --base HEAD --check "sh -c 'while :; do sleep 1; done' </dev/null >/dev/null 2>&1 & echo \$! > \"\$TMPDIR/bg.pid\"; echo \$! > '$BGF'" \
  --check 'kill -0 "$(cat "$TMPDIR/bg.pid")"' --baseline-on 126,127 "$T/kfix.patch"
chk "P22a two checks where check 1 starts a background process check 2 needs: graded in ONE run, check 2 sees it → rc 0, rcs [0,0]" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 0 ] && [ "$(fieldc 1 .rcs)" = "[0,0]" ] && [ -s "$BGF" ]'
chk "P22a …and nothing it started outlives the run (the group is reaped)" '! kill -0 "$(cat "$BGF")" 2>/dev/null && k_clean'
CNT="$T/second-run"; rm -f "$CNT"
run_pc --repo "$K" --base HEAD --check 'true' --check "if [ -e '$CNT' ]; then exit 1; fi; : > '$CNT'; exit 127" --baseline-on 126,127 "$T/kfix.patch"
chk "P22b a check-by-check rerun that does not fail with the graded rc again (127, then 1) pins nothing: rcs null, failedCheck null, no base compared (baseRc null), the tail says so" \
  '[ "$(field 1 .rc)" = 127 ] && [ "$(fieldc 1 "[.rcs, .failedCheck, .baseRc, .baseRcs]")" = "[null,null,null,null]" ] && field 1 .tail | grep -q "which check exited 127 is unknown" && k_clean'

# --- P23: source-bound import settings never reach a check -----------------------
SEENV="$T/seen-env"
OUT=$(PYTHONPATH=/x/src PYTHONHOME=/x PYTHONSTARTUP=/x/s.py NODE_PATH=/x/nm PERL5LIB=/x/lib "$PC" --repo "$R" --base HEAD \
  --check "printf '%s|%s|%s|%s|%s\n' \"\${PYTHONPATH-unset}\" \"\${PYTHONHOME-unset}\" \"\${PYTHONSTARTUP-unset}\" \"\${NODE_PATH-unset}\" \"\${PERL5LIB-unset}\" > '$SEENV'" "$T/fix.patch" 2>"$T/err"); RC=$?
chk "P23a PYTHONPATH, PYTHONHOME, PYTHONSTARTUP, NODE_PATH and PERL5LIB inherited by patch-check are all unset in the check" \
  '[ "$RC" -eq 0 ] && [ "$(field 1 .rc)" = 0 ] && [ "$(cat "$SEENV")" = "unset|unset|unset|unset|unset" ]'

echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
