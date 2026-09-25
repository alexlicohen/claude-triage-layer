#!/bin/bash
# Hermetic test suite for scripts/parity-suite.sh — the task-suite side of
# workflows/triage-parity.js. Uses only the tiny self-made synthetic tasks under
# test/fixtures/parity/suite (a git-source task whose repo is built here at test
# time, a generator task, a seeded review task); every case runs under one
# mktemp -d root; nothing touches this repo or the network, and no external CLI
# is ever really invoked (ext-run.sh is pointed at stubs that must not run).
#
# Covers: list (merge + taskDir, band/id order, every validation failure => exit
# 2 naming the task, duplicate ids); materialize (deterministic sha for git+setup
# and generator sources, fixed identity, origin removed, clean tree; the source
# repo's status/HEAD/index/refs untouched; clip-creator refused; .codex-deny /
# CODEX_DENY_REPOS propagated next to the clone and honoured by the REAL
# ext-run.sh for the clone and a worktree of it, a retired .agy-deny marker NOT
# propagated; out-dir guards; rollback);
# verify-task (ok, pre-solved base, broken solution, non-applying solution,
# review keys); the $HOME-path lint; the PARITY_ env map (verify-task export,
# unmapped => exit 2, .parity-env only with selfCheckEnv and never in a diff);
# fingerprint (HEAD move, tree/content change, generator, refusals);
# score-review math; parity-cost.sh on a synthetic transcript.
# shellcheck disable=SC2034  # values are read inside chk's eval'd conditions
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PS="$REPO_DIR/scripts/parity-suite.sh"
EXT_RUN="$REPO_DIR/scripts/ext-run.sh"
FIX="$REPO_DIR/test/fixtures/parity/suite"

for tool in jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "INCOMPLETE: $tool is required to run this suite." >&2; exit 1; }
done
[ -x "$PS" ] || { echo "INCOMPLETE: $PS is missing or not executable." >&2; exit 1; }
[ -d "$FIX" ] || { echo "INCOMPLETE: fixtures missing at $FIX." >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
unset CODEX_DENY_REPOS

PASS_COUNT=0
FAIL_COUNT=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"
# Hermetic: the deny walk stops at $HOME, so a machine-level marker above $T
# (e.g. a real $TMPDIR/.codex-deny) never leaks into these cases.
export HOME="$T"

OUT=""; ERR=""; RC=0
chk() {
  if eval "$2"; then echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL: $1"; echo "      rc=$RC out: $(printf '%s' "$OUT" | head -3) err: $(printf '%s' "$ERR" | head -3)"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
run_ps() { OUT=$("$PS" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
j() { printf '%s\n' "$OUT" | jq -r "$1"; }

# mksrc DIR — the git source of the g-fix task: calc.sh subtracts (the bug).
mksrc() {
  mkdir -p "$1"
  git -c init.defaultBranch=main init -q "$1"
  git -C "$1" config user.email ps@localhost
  git -C "$1" config user.name ps
  printf '#!/bin/sh\n# add two numbers\necho $(($1 - $2))\n' > "$1/calc.sh"
  git -C "$1" add calc.sh
  git -C "$1" commit -qm init
}
# mksuite DIR SRC — a copy of the fixture suite with g-fix pointed at SRC's HEAD.
mksuite() {
  cp -R "$FIX" "$1"
  jq --arg r "$2" --arg b "$(git -C "$2" rev-parse HEAD)" '.source.repo = $r | .source.base = $b' \
    "$1/1/g-fix/task.json" > "$1/tj" && mv "$1/tj" "$1/1/g-fix/task.json"
}
# edit_task FILE JQ — rewrite a task.json in place.
edit_task() { jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

SRC="$T/src/calcrepo"
mksrc "$SRC"
SUITE="$T/suite"
mksuite "$SUITE" "$SRC"

# ---- list -------------------------------------------------------------------
run_ps list --suite "$SUITE"
chk "L1: list prints every task sorted by band then id, each merged with its absolute taskDir" \
  '[ "$RC" -eq 0 ] && [ "$(j "map(.id) | join(\",\")")" = "g-fix,gen-fix,rev-seed" ] && [ "$(j ".[0].taskDir")" = "$SUITE/1/g-fix" ] && [ "$(j ".[1].checks[0]")" = "sh test_greet.sh" ] && [ "$(j ".[2].kind")" = review ]'

# Each invalid variant lives alone in a fresh suite, so the failure names exactly it.
bad_case() { # $1 name, $2 task dir rel (band/id), $3 jq edit (or "" for none), $4 extra shell (optional)
  local s="$T/bad-$BADN"
  BAD_TASK="$2"
  BADN=$((BADN + 1))
  mksuite "$s" "$SRC"
  [ -n "$3" ] && edit_task "$s/$2/task.json" "$3"
  [ -n "${4:-}" ] && eval "$4"
  run_ps list --suite "$s"
  chk "L2: invalid task ($1) => exit 2, names the task, nothing on stdout" \
    '[ "$RC" -eq 2 ] && [ -z "$OUT" ] && printf "%s" "$ERR" | grep -qF "$BAD_TASK/task.json"'
}
BADN=1
bad_case "no brief" 1/g-fix 'del(.brief)'
bad_case "band 5" 1/g-fix '.band = 5'
bad_case "band does not match its dir" 2/gen-fix '.band = 3'
bad_case "setup path escapes the task dir" 1/g-fix '.setup = "../x.patch"'
bad_case "absolute overlay" 2/gen-fix '.overlay = "/etc"'
bad_case "unknown vendor" 2/gen-fix '.vendors = ["claude", "gemini"]'
bad_case "review task not graded seeded" 3/rev-seed '.grading = "check"'
bad_case "rubric without a key" 2/gen-fix '.grading = "rubric"'
bad_case "id differs from its dir" 2/gen-fix '.id = "other"'
bad_case "relative git repo" 1/g-fix '.source.repo = "src"'
bad_case "build task with no checks" 2/gen-fix '.checks = []'
bad_case "missing solution file" 2/gen-fix '.solution = "nope.patch"'
bad_case "generator not executable" 2/gen-fix '' 'chmod -x "$s/2/gen-fix/gen.sh"'
bad_case "not JSON" 3/rev-seed '' 'printf "{" > "$s/3/rev-seed/task.json"'
# NO REAL PATHS TO CANDIDATES: brief/acceptance/checks never name a path under $HOME.
bad_case "a check runs a tool by its /Users/ path" 1/g-fix '.checks = ["/Users/someone/proj/.venv/bin/python -m pytest"]'
bad_case "a brief names ~/ " 2/gen-fix '.brief = "See ~/projects/x/CONVENTIONS.md for the style."'
bad_case "acceptance names \$HOME" 2/gen-fix '.acceptance = "${HOME}/proj/.venv/bin/mkdocs build passes"'
bad_case "a check names the actual home dir (Linux-style)" 1/g-fix '.checks = ["'"$T"'/tools/bin/lint x"]'
bad_case "selfCheckEnv not a boolean" 2/gen-fix '.selfCheckEnv = "yes"'
DUP="$T/dup"
mksuite "$DUP" "$SRC"
mkdir -p "$DUP/b4"; cp -R "$DUP/2/gen-fix" "$DUP/b4/gen-fix"; edit_task "$DUP/b4/gen-fix/task.json" '.band = 4'
run_ps list --suite "$DUP"
chk "L3: a duplicate id across bands => exit 2 naming it (a bN band dir is accepted)" \
  '[ "$RC" -eq 2 ] && [ -z "$OUT" ] && printf "%s" "$ERR" | grep -q "duplicate task id.*gen-fix"'
run_ps list --suite "$T/no-such-suite"
chk "L4: a missing suite dir is a usage error" '[ "$RC" -eq 2 ]'
HOK="$T/homeok"; mksuite "$HOK" "$SRC"
edit_task "$HOK/1/g-fix/task.json" '.checks = ["\"$PARITY_SH\" test_calc.sh"] | .selfCheckEnv = true'
run_ps list --suite "$HOK"
chk "L5: source.repo under \$HOME is exempt (never shown to candidates); \$PARITY_ checks and selfCheckEnv are valid" \
  '[ "$RC" -eq 0 ] && case "$SRC" in "$HOME"/*) true ;; *) false ;; esac && [ "$(j ".[0].checks[0]")" = "\"\$PARITY_SH\" test_calc.sh" ]'

# ---- materialize: determinism, identity, source untouched -------------------
printf 'uncommitted\n' >> "$SRC/calc.sh"   # the source may be dirty; that must survive untouched
printf 'scratch\n' > "$SRC/untracked.txt"
src_state() { git -C "$SRC" --no-optional-locks status --porcelain=v1 -uall; git -C "$SRC" rev-parse HEAD; git -C "$SRC" for-each-ref; cksum < "$SRC/.git/index"; git -C "$SRC" remote -v; }
SRC_BEFORE=$(src_state)
run_ps materialize --task "$SUITE/1/g-fix" --out "$T/m1"
M1_SHA=$(j .sha); M1_REPO=$(j .repo)
run_ps materialize --task "$SUITE/1/g-fix" --out "$T/m2"
chk "M1: git+setup materialize is deterministic (same sha in two fresh outs) and prints {repo, sha, denied}" \
  '[ "$RC" -eq 0 ] && [ -n "$M1_SHA" ] && [ "$(j .sha)" = "$M1_SHA" ] && [ "$M1_REPO" = "$T/m1/repo" ] && [ "$(printf "%s" "$OUT" | jq -c .denied)" = "{\"codex\":false}" ]'
chk "M2: the tree + setup is ONE orphan root commit with the fixed identity; tree clean; HEAD detached" \
  '[ "$(git -C "$T/m1/repo" log -1 --format=%an/%ae/%cn/%ad --date=unix)" = "parity/parity@localhost/parity/946684800" ] && [ -f "$T/m1/repo/NOTES.txt" ] && [ -z "$(git -C "$T/m1/repo" status --porcelain)" ] && ! git -C "$T/m1/repo" symbolic-ref -q HEAD >/dev/null'
chk "M2b: no source history — exactly one commit reachable, no branches/tags/remotes, no unreachable objects" \
  '[ "$(git -C "$T/m1/repo" rev-list --all --count)" -eq 1 ] && [ -z "$(git -C "$T/m1/repo" for-each-ref)" ] && [ -z "$(git -C "$T/m1/repo" remote)" ] && [ -z "$(git -C "$T/m1/repo" fsck --unreachable --no-reflogs 2>&1)" ]'
chk "M3: the clone has no remote (nothing can be pushed back into the source) and none of its uncommitted work" \
  '[ -z "$(git -C "$T/m1/repo" remote)" ] && ! grep -q uncommitted "$T/m1/repo/calc.sh" && [ ! -e "$T/m1/repo/untracked.txt" ]'
chk "M4: the source repo is untouched (status, HEAD, refs, index bytes, remotes)" '[ "$(src_state)" = "$SRC_BEFORE" ]'
git -C "$SRC" checkout -q -- calc.sh; rm -f "$SRC/untracked.txt"

run_ps materialize --task "$SUITE/2/gen-fix" --out "$T/g1"
G1_SHA=$(j .sha)
run_ps materialize --task "$SUITE/2/gen-fix" --out "$T/g2"
chk "M5: generator materialize is deterministic (fixed identity/dates reach the generator too)" \
  '[ "$RC" -eq 0 ] && [ -n "$G1_SHA" ] && [ "$(j .sha)" = "$G1_SHA" ] && [ -z "$(git -C "$T/g2/repo" status --porcelain)" ]'
chk "M5b: the generator's own commit (gen.sh's 'gen: greet') is also reduced to one root commit — no history, no unreachable objects" \
  '[ "$(git -C "$T/g1/repo" rev-list --all --count)" -eq 1 ] && [ -z "$(git -C "$T/g1/repo" for-each-ref)" ] && [ -z "$(git -C "$T/g1/repo" fsck --unreachable --no-reflogs 2>&1)" ]'

# ---- materialize: no source history reaches the repo (the ANSWER LEAK) ------
NHSRC="$T/nh/src"; mksrc "$NHSRC"
NH_BASE=$(git -C "$NHSRC" rev-parse HEAD)
printf 'echo $(($1 + $2))  # the seeded fix, must never leak\n' >> "$NHSRC/calc.sh"
git -C "$NHSRC" add calc.sh
git -C "$NHSRC" -c commit.gpgsign=false commit -qm "the fix (must never reach the materialized repo)"
NH_FIX=$(git -C "$NHSRC" rev-parse HEAD)
NHSUITE="$T/nhsuite"; mksuite "$NHSUITE" "$NHSRC"
jq --arg b "$NH_BASE" '.source.base = $b' "$NHSUITE/1/g-fix/task.json" > "$NHSUITE/1/g-fix/task.json.tmp" && mv "$NHSUITE/1/g-fix/task.json.tmp" "$NHSUITE/1/g-fix/task.json"
run_ps materialize --task "$NHSUITE/1/g-fix" --out "$T/nh-out"
chk "M12: a source commit AFTER base => the materialized repo has exactly one commit, no branches besides the documented (detached HEAD, none), no tags, no remotes, no unreachable objects" \
  '[ "$RC" -eq 0 ] && [ "$(git -C "$T/nh-out/repo" rev-list --all --count)" -eq 1 ] && [ -z "$(git -C "$T/nh-out/repo" for-each-ref)" ] && [ -z "$(git -C "$T/nh-out/repo" remote)" ] && [ -z "$(git -C "$T/nh-out/repo" fsck --unreachable --no-reflogs 2>&1)" ] && ! git -C "$T/nh-out/repo" symbolic-ref -q HEAD >/dev/null'
chk "M13: ...and the post-base commit's content and sha are both absent from the materialized repo" \
  '! git -C "$T/nh-out/repo" cat-file -e "$NH_FIX" 2>/dev/null && ! grep -qF "the seeded fix, must never leak" "$T/nh-out/repo/calc.sh"'
chk "M14: ...while setup content is present and the tree is a single commit (rev-list --count HEAD = 1)" \
  '[ -f "$T/nh-out/repo/NOTES.txt" ] && [ "$(git -C "$T/nh-out/repo" rev-list --count HEAD)" -eq 1 ]'
run_ps materialize --task "$SUITE/2/gen-fix" --out "$T/g1"
chk "M6: re-materializing into an out it made before rebuilds it (idempotent)" '[ "$RC" -eq 0 ] && [ "$(j .sha)" = "$G1_SHA" ]'
mkdir -p "$T/foreign"; : > "$T/foreign/keep.txt"
run_ps materialize --task "$SUITE/2/gen-fix" --out "$T/foreign"
chk "M7: a non-empty out it did not make is refused (exit 2) and left alone" '[ "$RC" -eq 2 ] && [ -f "$T/foreign/keep.txt" ] && [ ! -e "$T/foreign/repo" ]'
run_ps materialize --task "$SUITE/1/g-fix" --out "$SRC/sub/out"
chk "M8: an out inside the source repo is refused (exit 2) and nothing is written there" '[ "$RC" -eq 2 ] && [ ! -e "$SRC/sub" ]'
run_ps materialize --task "$SUITE/2/gen-fix" --out "$SUITE/2/gen-fix/out"
chk "M9: an out inside the task dir is refused (exit 2)" '[ "$RC" -eq 2 ] && [ ! -e "$SUITE/2/gen-fix/out" ]'
run_ps materialize --task "$SUITE/2/gen-fix" --out "relative/out"
chk "M10: a relative out is a usage error" '[ "$RC" -eq 2 ]'
NOC="$T/nocommit"; mksuite "$NOC" "$SRC"
printf '#!/bin/sh\nset -e\nmkdir -p "$1"\ngit -C "$1" init -q\n' > "$NOC/2/gen-fix/gen.sh"
run_ps materialize --task "$NOC/2/gen-fix" --out "$T/nc"
chk "M11: a generator that leaves no commit fails (exit 1) and its half-made repo is rolled back" '[ "$RC" -eq 1 ] && [ ! -e "$T/nc/repo" ]'

# ---- deny: clip-creator refused, markers and names propagated ---------------
CC="$T/x/clip-creator/tool"; mksrc "$CC"
CCS="$T/ccsuite"; mksuite "$CCS" "$CC"
run_ps materialize --task "$CCS/1/g-fix" --out "$T/cc-out"
chk "D1: a git source under clip-creator is REFUSED (exit 3) before anything is cloned" '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q clip-creator && [ ! -e "$T/cc-out/repo" ]'
CCT="$T/y/clip-creator/suite"; mkdir -p "$(dirname "$CCT")"; mksuite "$CCT" "$SRC"
run_ps materialize --task "$CCT/2/gen-fix" --out "$T/cct-out"
chk "D2: a task (generator source) under clip-creator is REFUSED (exit 3)" '[ "$RC" -eq 3 ] && [ ! -e "$T/cct-out/repo" ]'
chk "D3: parity-suite.sh's HARD_DENY_REPOS equals ext-run.sh's (ext-run owns deny decisions)" \
  '[ "$(sed -n "s/^HARD_DENY_REPOS=//p" "$PS")" = "$(sed -n "s/^HARD_DENY_REPOS=//p" "$EXT_RUN")" ]'

AD="$T/codexdenied/area"; mkdir -p "$AD"; : > "$T/codexdenied/.codex-deny"
mksrc "$AD/src"; ADS="$T/adsuite"; mksuite "$ADS" "$AD/src"
run_ps materialize --task "$ADS/1/g-fix" --out "$T/ad-out"
chk "D4: a .codex-deny above the source is propagated as <out>/.codex-deny (denied.codex true)" \
  '[ "$RC" -eq 0 ] && [ -f "$T/ad-out/.codex-deny" ] && [ "$(j .denied.codex)" = true ] && grep -q "$T/codexdenied/.codex-deny" "$T/ad-out/.codex-deny"'
chk "D5: the propagated marker sits outside the clone (the clone stays clean)" '[ -z "$(git -C "$T/ad-out/repo" status --porcelain)" ]'

AG="$T/agyleft/area"; mkdir -p "$AG"; : > "$T/agyleft/.agy-deny"
mksrc "$AG/src"; AGS="$T/agsuite"; mksuite "$AGS" "$AG/src"
run_ps materialize --task "$AGS/1/g-fix" --out "$T/ag-out"
chk "D4b: a leftover .agy-deny (agy retired) is NOT propagated and denied has only codex (false)" \
  '[ "$RC" -eq 0 ] && [ ! -e "$T/ag-out/.agy-deny" ] && [ ! -e "$T/ag-out/.codex-deny" ] && [ "$(printf "%s" "$OUT" | jq -c .denied)" = "{\"codex\":false}" ]'

mksrc "$T/cdn/src"; : > "$T/cdn/src/.codex-deny"; CDS="$T/cdsuite"; mksuite "$CDS" "$T/cdn/src"
run_ps materialize --task "$CDS/1/g-fix" --out "$T/cd-out"
chk "D6: a .codex-deny in the source repo root is propagated (denied.codex true)" \
  '[ "$RC" -eq 0 ] && [ -f "$T/cd-out/.codex-deny" ] && [ "$(j .denied.codex)" = true ]'

mksrc "$T/named/secretproj"; NS="$T/nsuite"; mksuite "$NS" "$T/named/secretproj"
OUT=$(CODEX_DENY_REPOS="secretproj" "$PS" materialize --task "$NS/1/g-fix" --out "$T/n-out" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
chk "D7: a CODEX_DENY_REPOS name matching the source path is propagated as <out>/.codex-deny" \
  '[ "$RC" -eq 0 ] && [ -f "$T/n-out/.codex-deny" ] && [ "$(j .denied.codex)" = true ]'

TD="$T/taskdeny"; mkdir -p "$TD"; mksuite "$TD/suite" "$SRC"; : > "$TD/.codex-deny"
run_ps materialize --task "$TD/suite/2/gen-fix" --out "$T/td-out"
chk "D8: a generator task under a .codex-deny tree carries that status to its repo" '[ "$RC" -eq 0 ] && [ "$(j .denied.codex)" = true ] && [ -f "$T/td-out/.codex-deny" ]'

# A source path WITH SPACES keeps its deny status (the source list is an array,
# never whitespace-split text).
mksrc "$T/sp ace/src"; : > "$T/sp ace/src/.codex-deny"; SPS="$T/spsuite"; mksuite "$SPS" "$T/sp ace/src"
# (bounded: word-splitting once turned "sp ace/src" into a relative path whose
# dirname walk never ended)
OUT=$(perl -e 'alarm shift; exec @ARGV' 60 "$PS" materialize --task "$SPS/1/g-fix" --out "$T/sp-out" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
chk "D13: a .codex-deny in a source repo whose path has a space is propagated (denied.codex true)" \
  '[ "$RC" -eq 0 ] && [ -f "$T/sp-out/.codex-deny" ] && [ "$(j .denied.codex)" = true ] && grep -qF "$T/sp ace/src/.codex-deny" "$T/sp-out/.codex-deny"'

# A marker exactly AT $HOME counts (the same walk as ext-run.sh, $HOME included).
HP="$T/homedeny"; mksrc "$HP/src"; : > "$HP/.codex-deny"; HPS="$T/hpsuite"; mksuite "$HPS" "$HP/src"
OUT=$(HOME="$HP" "$PS" materialize --task "$HPS/1/g-fix" --out "$T/hp-out" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
chk "D14: a .codex-deny at \$HOME itself is propagated (denied.codex true)" \
  '[ "$RC" -eq 0 ] && [ -f "$T/hp-out/.codex-deny" ] && [ "$(j .denied.codex)" = true ]'

# An inherited GIT_DIR/GIT_WORK_TREE (a hook's environment) must not redirect the
# source lookup or the materialized repo.
DECOY="$T/decoy"; mksrc "$DECOY"; printf 'decoy only\n' > "$DECOY/decoy.txt"; git -C "$DECOY" add decoy.txt; git -C "$DECOY" commit -qm decoy
DECOY_BEFORE=$({ git -C "$DECOY" status --porcelain; git -C "$DECOY" rev-parse HEAD; git -C "$DECOY" for-each-ref; })
OUT=$(GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" GIT_INDEX_FILE="$DECOY/.git/index" "$PS" materialize --task "$SUITE/1/g-fix" --out "$T/gd-out" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
chk "D15: with a decoy GIT_DIR/GIT_WORK_TREE inherited, materialize yields the same sha as M1 and leaves the decoy untouched" \
  '[ "$RC" -eq 0 ] && [ "$(j .sha)" = "$M1_SHA" ] && [ "$({ git -C "$DECOY" status --porcelain; git -C "$DECOY" rev-parse HEAD; git -C "$DECOY" for-each-ref; })" = "$DECOY_BEFORE" ]'

# A trailing value-taking flag is a usage error, never an endless loop.
OUT=$(perl -e 'alarm shift; exec @ARGV' 20 "$PS" materialize --task "$SUITE/1/g-fix" --out 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
chk "G1: a trailing --out with no value is exit 2 (needs a value)" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q -- "--out needs a value"'

# The owner of the deny decision, ext-run.sh, must refuse the clone and any
# worktree of it — with stub CLIs that must never be invoked.
if [ -x "$EXT_RUN" ]; then
  mkdir -p "$T/bin"
  printf '#!/bin/sh\n: > "%s/stub-called"\nexit 1\n' "$T" > "$T/bin/codex"; chmod +x "$T/bin/codex"
  printf 'Review this.\n' > "$T/brief.txt"
  ext() { OUT=$(AGY_BOUNDARY_CLEARED=1 CODEX_BIN="$T/bin/codex" "$EXT_RUN" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
  rm -f "$T/stub-called"
  ext read --prompt-file "$T/brief.txt" --input "$T/ad-out/repo/calc.sh"
  chk "D9: ext-run.sh REFUSES codex on a file in the materialized clone (exit 3) — the propagated marker works" \
    '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny" && [ ! -e "$T/stub-called" ]'
  git -C "$T/ad-out/repo" worktree add -q --detach "$T/ad-wt" >/dev/null 2>&1
  ext read --prompt-file "$T/brief.txt" --input "$T/ad-wt/calc.sh"
  chk "D10: ...and on a file in a linked worktree of the clone staged elsewhere (triage-compare's layout)" \
    '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny" && [ ! -e "$T/stub-called" ]'
  ext read --prompt-file "$T/brief.txt" --input "$T/ag-out/repo/calc.sh"
  chk "D11: ...while a clone of an .agy-deny source is NOT refused (the retired marker is inert)" '[ "$RC" -ne 3 ]'
  rm -f "$T/stub-called"
  ext read --prompt-file "$T/brief.txt" --input "$T/m1/repo/calc.sh"
  chk "D12: an unmarked clone is not refused by ext-run.sh" '[ "$RC" -ne 3 ]'
else
  chk "D9-D12: ext-run.sh present" 'false'
fi

# ---- verify-task --------------------------------------------------------------
run_ps verify-task --task "$SUITE/1/g-fix" --out "$T/v1"
chk "V1: verify-task on the git task: base fails, solution passes, ok (exit 0)" \
  '[ "$RC" -eq 0 ] && [ "$(j .baseFails)" = true ] && [ "$(j .solutionPasses)" = true ] && [ "$(j .ok)" = true ] && [ "$(j .id)" = g-fix ]'
run_ps verify-task --task "$SUITE/2/gen-fix" --out "$T/v2"
chk "V2: verify-task on the generator task is ok" '[ "$RC" -eq 0 ] && [ "$(j .ok)" = true ]'
chk "V3: verify-task leaves no stray worktree registered in the materialized repo" \
  '[ "$(git -C "$T/v2/repo" worktree list --porcelain | grep -c "^worktree ")" -eq 1 ]'
EXTRA_PATCH='diff --git a/EXTRA.txt b/EXTRA.txt
new file mode 100644
--- /dev/null
+++ b/EXTRA.txt
@@ -0,0 +1 @@
+x
'
PRE="$T/presolved"; mksuite "$PRE" "$SRC"
cp "$PRE/1/g-fix/solution.patch" "$PRE/1/g-fix/fix.patch"
edit_task "$PRE/1/g-fix/task.json" 'del(.setup) | .setup = "fix.patch"'
printf '%s' "$EXTRA_PATCH" > "$PRE/1/g-fix/solution.patch"
run_ps verify-task --task "$PRE/1/g-fix" --out "$T/v3"
chk "V4: a pre-solved base (checks already pass) => baseFails false, ok false, exit 1" \
  '[ "$RC" -eq 1 ] && [ "$(j .baseFails)" = false ] && [ "$(j .solutionPasses)" = true ] && [ "$(j .ok)" = false ]'
BRK="$T/broken"; mksuite "$BRK" "$SRC"
printf '%s' "$EXTRA_PATCH" > "$BRK/1/g-fix/solution.patch"
run_ps verify-task --task "$BRK/1/g-fix" --out "$T/v4"
chk "V5: a solution that applies but does not fix => solutionPasses false, ok false, exit 1" \
  '[ "$RC" -eq 1 ] && [ "$(j .baseFails)" = true ] && [ "$(j .solutionPasses)" = false ] && [ "$(j .ok)" = false ]'
NAP="$T/noapply"; mksuite "$NAP" "$SRC"
sed 's/echo \$((\$1 - \$2))/echo WRONG CONTEXT/' "$SUITE/1/g-fix/solution.patch" > "$NAP/1/g-fix/solution.patch"
run_ps verify-task --task "$NAP/1/g-fix" --out "$T/v5"
chk "V6: a solution that does not apply => solutionPasses false, ok false" '[ "$RC" -eq 1 ] && [ "$(j .solutionPasses)" = false ]'
NOS="$T/nosol"; mksuite "$NOS" "$SRC"; edit_task "$NOS/2/gen-fix/task.json" 'del(.solution)'
run_ps verify-task --task "$NOS/2/gen-fix" --out "$T/v6"
chk "V7: a build task without a solution cannot be proven solvable => ok false" '[ "$RC" -eq 1 ] && [ "$(j .ok)" = false ] && [ "$(j .solutionPasses)" = null ]'
run_ps verify-task --task "$SUITE/3/rev-seed" --out "$T/v7"
chk "V8: verify-task on the review task: key parses, 3 seeds, every seeded file exists at the sha" \
  '[ "$RC" -eq 0 ] && [ "$(j .seeds)" = 3 ] && [ "$(j ".missing | length")" = 0 ] && [ "$(j .ok)" = true ]'
OVF="$T/ovfail"; mksuite "$OVF" "$SRC"
mkdir -p "$OVF/1/g-fix/hidden/calc.sh"; printf 'x\n' > "$OVF/1/g-fix/hidden/calc.sh/inner"
run_ps verify-task --task "$OVF/1/g-fix" --out "$T/v10"
chk "V11: an overlay that cannot be copied (hidden tests missing) is no grade: baseFails AND solutionPasses false, ok false, error overlay-failed" \
  '[ "$RC" -eq 1 ] && [ "$(j .baseFails)" = false ] && [ "$(j .solutionPasses)" = false ] && [ "$(j .ok)" = false ] && [ "$(j .error)" = overlay-failed ]'
RK="$T/rk"; mksuite "$RK" "$SRC"; printf '[]\n' > "$RK/3/rev-seed/key.json"
run_ps verify-task --task "$RK/3/rev-seed" --out "$T/v8"
chk "V9: an empty seed list => ok false" '[ "$RC" -eq 1 ] && [ "$(j .ok)" = false ]'
RM="$T/rm"; mksuite "$RM" "$SRC"; printf '[{"file":"gone.py","line":1,"id":"S1","desc":"d"}]\n' > "$RM/3/rev-seed/key.json"
run_ps verify-task --task "$RM/3/rev-seed" --out "$T/v9"
chk "V10: a seed naming a file absent at the sha => missing lists it, ok false" '[ "$RC" -eq 1 ] && [ "$(j ".missing[0]")" = gone.py ]'

# ---- (d) env map: $PARITY_ tool variables, .parity-env only on opt-in ----------
EM="$T/envs.json"; printf '{"PARITY_SH":"/bin/sh","PARITY_UNUSED":"/nowhere"}\n' > "$EM"
ES="$T/envsuite"; mksuite "$ES" "$SRC"
edit_task "$ES/1/g-fix/task.json" '.checks = ["\"$PARITY_SH\" test_calc.sh"]'
cp -R "$ES/1/g-fix" "$ES/1/g-self"; edit_task "$ES/1/g-self/task.json" '.id = "g-self" | .selfCheckEnv = true'
run_ps verify-task --task "$ES/1/g-fix" --out "$T/e1" --env-map "$EM"
chk "E1: verify-task exports the mapped PARITY_ variable into the checks (base fails, solution passes: the tool ran)" \
  '[ "$RC" -eq 0 ] && [ "$(j .baseFails)" = true ] && [ "$(j .solutionPasses)" = true ] && [ "$(j .ok)" = true ]'
OUT=$(PARITY_ENV_MAP="$EM" "$PS" verify-task --task "$ES/1/g-fix" --out "$T/e1b" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
chk "E1b: ...and PARITY_ENV_MAP names the map when --env-map is absent" '[ "$RC" -eq 0 ] && [ "$(j .ok)" = true ]'
printf '{"PARITY_OTHER":"/bin/sh"}\n' > "$T/envs-other.json"
run_ps verify-task --task "$ES/1/g-fix" --out "$T/e2" --env-map "$T/envs-other.json"
chk "E2: an UNMAPPED variable a check references => exit 2 naming it, nothing materialized" \
  '[ "$RC" -eq 2 ] && [ -z "$OUT" ] && printf "%s" "$ERR" | grep -q "PARITY_SH" && [ ! -e "$T/e2/repo" ]'
run_ps materialize --task "$ES/1/g-fix" --out "$T/e3"
chk "E3: materialize with no env map (HOME has none) and a \$PARITY_ check => exit 2 naming it" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "PARITY_SH" && [ ! -e "$T/e3/repo" ]'
run_ps materialize --task "$ES/1/g-fix" --out "$T/e4" --env-map "$EM"
chk "E4: a task that does not opt in gets NO .parity-env (and no exclude line for it)" \
  '[ "$RC" -eq 0 ] && [ ! -e "$T/e4/repo/.parity-env" ] && ! grep -q parity-env "$T/e4/repo/.git/info/exclude" 2>/dev/null'
run_ps materialize --task "$ES/1/g-self" --out "$T/e5" --env-map "$EM"
E5_SHA=$(j .sha)
chk "E5: selfCheckEnv:true writes <repo>/.parity-env holding ONLY the referenced variables' export lines" \
  '[ "$RC" -eq 0 ] && grep -qx "export PARITY_SH='"'"'/bin/sh'"'"'" "$T/e5/repo/.parity-env" && ! grep -q PARITY_UNUSED "$T/e5/repo/.parity-env"'
chk "E5b: ...it is git-excluded: the tree stays clean and the committed tree is the same as without it" \
  '[ -z "$(git -C "$T/e5/repo" status --porcelain --ignored=no)" ] && git -C "$T/e5/repo" check-ignore -q .parity-env && [ "$(git -C "$T/e5/repo" rev-parse "HEAD^{tree}")" = "$(git -C "$T/e4/repo" rev-parse "HEAD^{tree}")" ]'
chk "E5c: ...and sourcing it gives a candidate the tool (the checks run by hand)" \
  '( cd "$T/e5/repo" && . ./.parity-env && [ "$PARITY_SH" = /bin/sh ] )'
SW="$REPO_DIR/scripts/stage-worktree.sh"
git -C "$T/e5/repo" worktree add -q --detach "$T/e5-wt" >/dev/null 2>&1
cp "$T/e5/repo/.parity-env" "$T/e5-wt/.parity-env"; printf 'x\n' > "$T/e5-wt/candidate-change.txt"
"$SW" diff --worktree "$T/e5-wt" --base "$E5_SHA" --out "$T/e5.patch" >/dev/null 2>&1
chk "E5d: a .parity-env copied into a worktree never enters the candidate's patch (the exclude is shared)" \
  'grep -q "candidate-change.txt" "$T/e5.patch" && ! grep -q "parity-env" "$T/e5.patch"'

# ---- (b) fingerprint: the source-repo leak guard ----------------------------------
FS="$T/fpsrc"; mksrc "$FS"; FPS="$T/fpsuite"; mksuite "$FPS" "$FS"
fp_state() { git -C "$FS" --no-optional-locks status --porcelain=v1 -uall; git -C "$FS" rev-parse HEAD; cksum < "$FS/.git/index"; }
FS_BEFORE=$(fp_state)
run_ps fingerprint --task "$FPS/1/g-fix"
FP0="$OUT"
chk "F1: a git source prints {id, source:git, name, head, tree} — the repo NAME only, never its path" \
  '[ "$RC" -eq 0 ] && [ "$(j .source)" = git ] && [ "$(j .name)" = fpsrc ] && [ "$(j .head)" = "$(git -C "$FS" rev-parse HEAD)" ] && printf "%s" "$(j .tree)" | grep -Eq "^[0-9a-f]{40}$" && ! printf "%s" "$OUT" | grep -qF "$FS"'
chk "F1b: fingerprinting leaves the source untouched (status, HEAD, index bytes)" '[ "$(fp_state)" = "$FS_BEFORE" ]'
run_ps fingerprint --task "$FPS/1/g-fix"
chk "F2: an unchanged source fingerprints identically" '[ "$OUT" = "$FP0" ]'
printf 'dirty\n' >> "$FS/calc.sh"
run_ps fingerprint --task "$FPS/1/g-fix"; FP1="$OUT"
chk "F3: a tracked edit changes tree, not head (tree changed)" \
  '[ "$(printf "%s" "$FP1" | jq -r .head)" = "$(printf "%s" "$FP0" | jq -r .head)" ] && [ "$(printf "%s" "$FP1" | jq -r .tree)" != "$(printf "%s" "$FP0" | jq -r .tree)" ]'
printf 'dirtier\n' >> "$FS/calc.sh"
run_ps fingerprint --task "$FPS/1/g-fix"
chk "F4: a second edit to an already-dirty file changes tree again (content, not just status)" '[ "$(j .tree)" != "$(printf "%s" "$FP1" | jq -r .tree)" ]'
FP2="$OUT"
printf 'new\n' > "$FS/planted.md"
run_ps fingerprint --task "$FPS/1/g-fix"
chk "F5: an untracked file planted in the source changes tree" '[ "$(j .tree)" != "$(printf "%s" "$FP2" | jq -r .tree)" ]'
git -C "$FS" add -A; git -C "$FS" commit -qm "a concurrent commit"
run_ps fingerprint --task "$FPS/1/g-fix"
chk "F6: a commit moves head (HEAD moved)" '[ "$(j .head)" = "$(git -C "$FS" rev-parse HEAD)" ] && [ "$(j .head)" != "$(printf "%s" "$FP0" | jq -r .head)" ]'
run_ps fingerprint --task "$FPS/2/gen-fix"
chk "F7: a generator source prints {id, source:generator} and nothing to compare" '[ "$RC" -eq 0 ] && [ "$OUT" = "{\"id\":\"gen-fix\",\"source\":\"generator\"}" ]'
run_ps fingerprint --task "$CCS/1/g-fix"
chk "F8: a clip-creator source is REFUSED (exit 3)" '[ "$RC" -eq 3 ]'
GONE="$T/gonesuite"; mksuite "$GONE" "$SRC"; edit_task "$GONE/1/g-fix/task.json" '.source.repo = "'"$T"'/no/such/repo"'
run_ps fingerprint --task "$GONE/1/g-fix"
chk "F9: a missing source repo => exit 1 (the guard reports unverified, never clean)" '[ "$RC" -eq 1 ] && [ -z "$OUT" ]'

# ---- score-review -------------------------------------------------------------
KEY="$FIX/3/rev-seed/key.json"   # S1 app.py:3, S2 app.py:9, S3 app.py:13
score() { printf '%s' "$1" > "$T/f.json"; run_ps score-review --key "$KEY" --findings "$T/f.json"; }
score '[{"file":"app.py","line":12,"desc":"a"},{"file":"./app.py","line":9,"desc":"b"},{"file":"app.py","line":9,"desc":"dup"},{"file":"other.py","line":3,"desc":"c"},{"file":"/abs/x/app.py","line":4,"desc":"d"}]'
chk "S1: closest-first matching, each seed once, ./ and absolute-suffix paths: recall 1, precision 3/5, matched in key order" \
  '[ "$RC" -eq 0 ] && [ "$(j .recall)" = 1 ] && [ "$(j .precision)" = 0.6 ] && [ "$(j ".matched | join(\",\")")" = "S1,S2,S3" ] && [ "$(j .findings)" = 5 ]'
score '[{"file":"app.py","line":12,"desc":"1 from S3, 3 from S2"},{"file":"app.py","line":13,"desc":"on S3"}]'
chk "S2: closest-first, not first-come: line 13 takes S3 (d 0), so line 12 falls back to S2 (d 3) => recall 2/3, precision 1" \
  '[ "$(j ".matched | join(\",\")")" = "S2,S3" ] && [ "$(j .precision)" = 1 ] && [ "$(j "(.recall * 1000 | floor)")" = 666 ]'
score '{"findings":[{"file":"app.py","line":17,"desc":"4 lines off S3"},{"file":"app.py","line":"13","desc":"string line"}]}'
chk "S3: a {findings:[...]} wrapper works, |diff| 4 does not match, a numeric-string line does => recall 1/3, precision 1/2" \
  '[ "$(j ".matched | join(\",\")")" = "S3" ] && [ "$(j .precision)" = 0.5 ]'
score '[]'
chk "S4: no findings => recall 0, precision 0" '[ "$RC" -eq 0 ] && [ "$(j .recall)" = 0 ] && [ "$(j .precision)" = 0 ] && [ "$(j ".matched | length")" = 0 ]'
score '[{"file":"app.py","line":9,"desc":"x"}]'
chk "S5: one exact hit => recall 1/3, precision 1" '[ "$(j .precision)" = 1 ] && [ "$(j ".matched[0]")" = S2 ]'
printf 'not json' > "$T/bad.json"
run_ps score-review --key "$KEY" --findings "$T/bad.json"
chk "S6: unparseable findings are a usage error (exit 2), never a silent zero" '[ "$RC" -eq 2 ]'

# ---- parity-cost.sh ---------------------------------------------------------------
# Fixture: a1 candidate:x (sonnet; m1 repeated with a growing output 1 -> 50, m2,
# a partial last line), a2 candidate:x-r2 (haiku, reuses the id m1 in another
# file), a3 candidate:y@rev-seed (opus, two id-less messages), a4 grade:finalize,
# nested/a5 with no meta.json.
PC="$REPO_DIR/scripts/parity-cost.sh"
COST="$REPO_DIR/test/fixtures/parity/cost/wf_fix"
OUT=$("$PC" "$COST" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
chk "C1: totals over every agent below the dir (recursive), each message id once with its max usage" \
  '[ "$RC" -eq 0 ] && [ "$(j .agents)" = 5 ] && [ "$(j ".total | [.input,.cacheRead,.cacheWrite,.output,.messages] | join(\",\")")" = "24,340,33,110,7" ]'
chk "C2: per label: candidate:x counts m1 once at output 50 (not 51), skips the partial line" \
  '[ "$(j ".byLabel[\"candidate:x\"] | [.input,.cacheRead,.cacheWrite,.output,.messages,.agentType] | join(\",\")")" = "15,300,20,80,2,triage-builder" ]'
chk "C3: per model sums" \
  '[ "$(j ".byModel[\"claude-haiku-4-5\"] | [.input,.output,.messages] | join(\",\")")" = "5,12,3" ] && [ "$(j ".byModel[\"claude-opus-5-5\"].output")" = 18 ] && [ "$(j ".byModel[\"claude-sonnet-5\"].output")" = 80 ]'
chk "C4: per candidate: -rN folds onto its label (x = a1 + a2, by model), @task is stripped (y), id-less messages each count" \
  '[ "$(j ".byCandidate | keys | join(\",\")")" = "x,y" ] && [ "$(j ".byCandidate.x | [.input,.output,.messages] | join(\",\")")" = "16,87,3" ] && [ "$(j ".byCandidate.x.models | keys | join(\",\")")" = "claude-haiku-4-5,claude-sonnet-5" ] && [ "$(j ".byCandidate.y | [.output,.messages] | join(\",\")")" = "18,2" ]'
chk "C5: grading/unlabelled agents are overhead, never a candidate" \
  '[ "$(j ".overhead | [.input,.output,.messages] | join(\",\")")" = "4,5,2" ] && [ "$(j ".byLabel[\"(unlabelled)\"].agentType")" = unknown ]'
mkdir -p "$T/empty-wf"
OUT=$("$PC" "$T/empty-wf" 2>"$T/err"); RC=$?
chk "C6: no transcripts => INCOMPLETE exit 5, never zeros" '[ "$RC" -eq 5 ] && [ -z "$OUT" ]'
mkdir -p "$T/nousage-wf"; printf '{"type":"user"}\n' > "$T/nousage-wf/agent-z.jsonl"
OUT=$("$PC" "$T/nousage-wf" 2>"$T/err"); RC=$?
chk "C7: transcripts without usage => INCOMPLETE exit 5" '[ "$RC" -eq 5 ]'
OUT=$("$PC" "$T/nope" 2>"$T/err"); RC=$?
chk "C8: a missing dir is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

echo ""
echo "parity-suite: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
