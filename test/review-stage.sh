#!/bin/bash
# Hermetic test suite for scripts/review-stage.sh — the staging area of a review
# bake-off (workflows/triage-compare.js kind:'review'). Every case runs against
# synthetic git repos under one mktemp -d root with HOME pointed into it; nothing
# here touches this repo, ~/.agents or the network.
#
# Covers: the snapshot is the ARCHIVE of the head commit, never the live tree
# (uncommitted edits and untracked files absent); include / exclude / context
# filtering with :(glob) semantics; HARD EXCLUDES (context/, PROJECT_MEMORY*.md,
# --hard-exclude) winning over include, context and git tracking, at any depth,
# out of the snapshot AND the range diff, listed in the manifest; symlinks
# dropped; extras copied (and refused inside the repo / onto a hard-excluded
# name); range.diff exactly `git diff B H` of the included paths; out-dir
# refusals (inside / containing the repo, not empty); the .codex-deny carry-over;
# the live repo untouched; fingerprint scoped to its paths (a change outside them,
# or a hard-excluded one, is not a change; a second edit to a dirty file is);
# compare exit codes; HARD_DENY_REPOS in step with ext-run.sh.
# shellcheck disable=SC2034  # *_BEFORE etc. are read inside chk's eval'd conditions
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RS="$REPO_DIR/scripts/review-stage.sh"

for tool in jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "INCOMPLETE: $tool is required to run this suite." >&2; exit 1; }
done
[ -x "$RS" ] || { echo "INCOMPLETE: $RS is missing or not executable." >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

PASS_COUNT=0
FAIL_COUNT=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HOME="$T"
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"

OUT=""; ERR=""; RC=0
chk() {
  if eval "$2"; then echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else echo "FAIL: $1"; echo "      rc=$RC out: $(printf '%s' "$OUT" | head -3) err: $(printf '%s' "$ERR" | head -3)"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
}
run_rs() { OUT=$("$RS" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
j() { printf '%s\n' "$OUT" | jq -r "$1"; }
g() { git -C "$R" "$@"; }

# --- the fixture repo ---------------------------------------------------------
R="$T/repo"
git -c init.defaultBranch=main init -q "$R"
g config user.email rs@localhost; g config user.name rs
mkdir -p "$R/docs/manual/print" "$R/docs/draft" "$R/docs/manual/context" "$R/context" "$R/review" "$R/tools" "$R/secret" "$R/site"
printf 'a1\n' > "$R/docs/manual/a.md"
printf 'b1\n' > "$R/docs/manual/print/b.md"
printf 'draft\n' > "$R/docs/draft/d.md"
printf 'rubric\n' > "$R/review/RUBRIC.md"
printf 'other review\n' > "$R/review/WORKLIST.md"
printf 'tool\n' > "$R/tools/x.py"
printf 'PNG\n' > "$R/docs/manual/x.png"
printf 'site\n' > "$R/site/index.md"
# Tracked on purpose: hard excludes must win even over git tracking.
printf 'SECRET-ORDERS\n' > "$R/context/orders.md"
printf 'SECRET-PM\n' > "$R/PROJECT_MEMORY.md"
printf 'SECRET-PM-ARCHIVE\n' > "$R/docs/PROJECT_MEMORY.archive.md"
printf 'SECRET-NESTED\n' > "$R/docs/manual/context/n.md"
printf 'SECRET-EXTRA-HARD\n' > "$R/secret/s.md"
ln -s a.md "$R/docs/manual/link.md"
g add -A && g commit -qm base
B=$(g rev-parse HEAD)
printf 'a2\n' >> "$R/docs/manual/a.md"
printf 'new\n' > "$R/docs/manual/new.md"
printf 'draft2\n' >> "$R/docs/draft/d.md"
printf 'SECRET-ORDERS-2\n' >> "$R/context/orders.md"
printf 'SECRET-PM-2\n' >> "$R/PROJECT_MEMORY.md"
printf 'SECRET-EXTRA-HARD-2\n' >> "$R/secret/s.md"
printf 'rubric2\n' >> "$R/review/RUBRIC.md"
g add -A && g commit -qm head
H=$(g rev-parse HEAD)
# Live, uncommitted state that must NOT reach the snapshot.
printf 'LIVE-EDIT\n' >> "$R/docs/manual/a.md"
printf 'LIVE-UNTRACKED\n' > "$R/docs/manual/untracked.md"
printf 'LIVE-PM\n' > "$R/docs/PROJECT_MEMORY.md"
STATUS_BEFORE=$(g status --porcelain=v1 -uall)
HEAD_BEFORE=$(g rev-parse HEAD)
INDEX_BEFORE=$(cksum < "$R/.git/index")

CAD="$T/cache/voron-cad/index.json"
mkdir -p "$(dirname "$CAD")"
printf '{"fasteners": 42}\n' > "$CAD"

O="$T/out1"
run_rs snapshot --repo "$R" --base "$B" --head HEAD --include 'docs/manual/**/*.md' '**/PROJECT_MEMORY*.md' --include 'secret/**' \
  --exclude 'docs/draft' --context review/RUBRIC.md tools/x.py context/orders.md --extra "$CAD:cad/index.json" --hard-exclude secret/ --out "$O"
SNAP="$O/snap"
man() { jq -r "$1" "$O/manifest.json"; }

# --- S1: the archive of H, never the live tree -----------------------------------
chk "S1 snapshot exits 0 and prints one JSON line with ok, the resolved base/head shas and the paths" \
  '[ "$RC" -eq 0 ] && [ "$(j .step)" = snapshot ] && [ "$(j .ok)" = true ] && [ "$(j .base)" = "$B" ] && [ "$(j .head)" = "$H" ] && [ "$(j .snap)" = "$SNAP" ] && [ "$(j .diff)" = "$O/range.diff" ]'
chk "S1b a file edited in the live tree is snapshotted as COMMITTED at head (no live edit)" \
  '[ "$(cat "$SNAP/docs/manual/a.md")" = "$(printf "a1\na2")" ] && ! grep -rq "LIVE-" "$O"'
chk "S1c an untracked live file is absent; no .git anywhere in the out dir" \
  '[ ! -e "$SNAP/docs/manual/untracked.md" ] && [ -z "$(find "$O" -name .git)" ]'
chk "S1d the live repo is untouched: same HEAD, same status, same index bytes" \
  '[ "$(g rev-parse HEAD)" = "$HEAD_BEFORE" ] && [ "$(g status --porcelain=v1 -uall)" = "$STATUS_BEFORE" ] && [ "$(cksum < "$R/.git/index")" = "$INDEX_BEFORE" ]'

# --- S2: include / exclude / context --------------------------------------------
chk "S2 include globs select nested and top-level matches (docs/manual/**/*.md = a.md, new.md, print/b.md)" \
  '[ -f "$SNAP/docs/manual/a.md" ] && [ -f "$SNAP/docs/manual/new.md" ] && [ -f "$SNAP/docs/manual/print/b.md" ]'
chk "S2b exclude drops docs/draft; files matching nothing (x.png, site/, WORKLIST.md) are absent" \
  '[ ! -e "$SNAP/docs/draft" ] && [ ! -e "$SNAP/docs/manual/x.png" ] && [ ! -e "$SNAP/site" ] && [ ! -e "$SNAP/review/WORKLIST.md" ]'
chk "S2c context files are added (review/RUBRIC.md at head, tools/x.py)" \
  '[ "$(cat "$SNAP/review/RUBRIC.md")" = "$(printf "rubric\nrubric2")" ] && [ -f "$SNAP/tools/x.py" ]'
chk "S2d a symlink is never staged; the manifest says why" \
  '[ ! -e "$SNAP/docs/manual/link.md" ] && [ ! -L "$SNAP/docs/manual/link.md" ] && [ "$(man ".excluded[] | select(.path == \"docs/manual/link.md\") | .reason")" = symlink ]'
chk "S2e manifest.files lists exactly the staged files with their byte counts" \
  '[ "$(man "[.files[].path] | join(\",\")")" = "docs/manual/a.md,docs/manual/new.md,docs/manual/print/b.md,review/RUBRIC.md,tools/x.py" ] &&
   [ "$(man ".files[] | select(.path == \"docs/manual/a.md\") | .bytes")" = 6 ] && [ "$(j .files)" = 5 ]'

# --- S3: hard excludes win over include, context and tracking ------------------------
chk "S3 tracked context/orders.md is absent though --context names it; nested docs/manual/context/ too (any depth)" \
  '[ ! -e "$SNAP/context" ] && [ ! -e "$SNAP/docs/manual/context" ]'
chk "S3b tracked PROJECT_MEMORY.md and PROJECT_MEMORY.archive.md are absent though an include names them" \
  '[ -z "$(find "$SNAP" -name "PROJECT_MEMORY*")" ]'
chk "S3c an extra --hard-exclude (secret/) wins over an include of secret/**" '[ ! -e "$SNAP/secret" ]'
chk "S3d no hard-excluded CONTENT anywhere in the out dir (snapshot, range.diff, manifest)" '! grep -rq "SECRET-" "$O"'
chk "S3e the manifest lists every hard-excluded path with its pattern" \
  '[ "$(man "[.excluded[] | select(.reason == \"hard-exclude\") | .path + \"=\" + .pattern] | join(\",\")")" = "PROJECT_MEMORY.md=PROJECT_MEMORY*.md,context/orders.md=context/,docs/PROJECT_MEMORY.archive.md=PROJECT_MEMORY*.md,docs/manual/context/n.md=context/,secret/s.md=secret/" ]'
chk "S3f the manifest records the hard excludes applied (defaults first)" \
  '[ "$(man ".hardExclude | join(\",\")")" = "context/,PROJECT_MEMORY*.md,secret/" ]'

# --- S4: range.diff = git diff B H over the included paths, minus hard excludes -------
EXPECT="$T/expect.diff"
git -C "$R" diff --no-color --no-renames --no-ext-diff --no-textconv -U3 --src-prefix=a/ --dst-prefix=b/ "$B" "$H" -- docs/manual/a.md docs/manual/new.md > "$EXPECT"
chk "S4 range.diff is exactly git diff base..head of the included paths (a.md hunk + new.md), nothing else" 'cmp -s "$EXPECT" "$O/range.diff"'
chk "S4b the excluded (docs/draft) and hard-excluded (context/, PROJECT_MEMORY, secret/) changes are not in it" \
  '! grep -q "draft\|orders\|PROJECT_MEMORY\|secret" "$O/range.diff"'
chk "S4c context files are not diffed (RUBRIC.md changed but is context only)" '! grep -q "RUBRIC" "$O/range.diff"'

# --- S5: extras ---------------------------------------------------------------------
chk "S5 an --extra is copied to snap/_extra/DEST byte-for-byte and listed in the manifest" \
  'cmp -s "$CAD" "$SNAP/_extra/cad/index.json" && [ "$(man ".extras[0].dest")" = "_extra/cad/index.json" ] && [ "$(j .extras)" = 1 ]'
O2="$T/out2"
run_rs snapshot --repo "$R" --base "$B" --head HEAD --include 'docs/**' --extra "$R/tools/x.py:x.py" --out "$O2"
chk "S5b an --extra inside the repo is refused (exit 2) — repo content comes only from the commit; nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$O2" ]'
run_rs snapshot --repo "$R" --base "$B" --head HEAD --include 'docs/**' --extra "$CAD:notes/PROJECT_MEMORY.md" --out "$O2"
chk "S5c an --extra whose DEST is hard-excluded is refused (exit 2)" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "hard exclude" && [ ! -e "$O2" ]'
mkdir -p "$T/elsewhere/context"; printf 'x\n' > "$T/elsewhere/context/c.json"
run_rs snapshot --repo "$R" --base "$B" --head HEAD --include 'docs/**' --extra "$T/elsewhere/context/c.json:c.json" --out "$O2"
chk "S5d an --extra whose SOURCE path has a hard-excluded component is refused (exit 2)" '[ "$RC" -eq 2 ] && [ ! -e "$O2" ]'
run_rs snapshot --repo "$R" --base "$B" --head HEAD --include 'docs/**' --extra "$CAD:../escape.json" --out "$O2"
chk "S5e an --extra DEST with .. is refused (exit 2)" '[ "$RC" -eq 2 ] && [ ! -e "$O2" ] && [ ! -e "$T/escape.json" ]'
run_rs snapshot --repo "$R" --base "$B" --head HEAD --include 'docs/**' --extra "$T/cache" --out "$O2"
chk "S5f an --extra without :DEST is refused (exit 2)" '[ "$RC" -eq 2 ] && [ ! -e "$O2" ]'

# --- S6: the out dir and the arguments ------------------------------------------------
run_rs snapshot --repo "$R" --base "$B" --head HEAD --include 'docs/**' --out "$R/review-out"
chk "S6 --out inside the repo is refused (exit 2), nothing written" '[ "$RC" -eq 2 ] && [ ! -e "$R/review-out" ]'
run_rs snapshot --repo "$R" --base "$B" --head HEAD --include 'docs/**' --out "$T"
chk "S6b --out containing the repo is refused (exit 2)" '[ "$RC" -eq 2 ]'
run_rs snapshot --repo "$R" --base "$B" --head HEAD --include 'docs/**' --out "$O"
chk "S6c a non-empty --out (a previous review) is refused (exit 2) and left as it was" '[ "$RC" -eq 2 ] && [ -f "$O/manifest.json" ] && [ -d "$SNAP" ]'
for badglob in /etc 'docs/../..' ':(top)docs' '-x'; do
  run_rs snapshot --repo "$R" --base "$B" --head HEAD --include "$badglob" --out "$T/out-bad"
  chk "S6d --include '$badglob' is refused (exit 2)" '[ "$RC" -eq 2 ] && [ ! -e "$T/out-bad" ]'
done
run_rs snapshot --repo "$R" --base nosuchrev --head HEAD --include 'docs/**' --out "$T/out-bad"
chk "S6e a --base that names no commit is refused (exit 2)" '[ "$RC" -eq 2 ] && [ ! -e "$T/out-bad" ]'
run_rs snapshot --repo "$R" --base "$B" --head HEAD --out "$T/out-bad"
chk "S6f no --include is a usage error (exit 2)" '[ "$RC" -eq 2 ]'
mkdir -p "$T/out-empty"
run_rs snapshot --repo "$R" --base "$B" --head "$B" --include 'docs/manual/*.md' --out "$T/out-empty"
chk "S6g an EMPTY existing --out is fine; base == head gives an empty range.diff and the base's files" \
  '[ "$RC" -eq 0 ] && [ ! -s "$T/out-empty/range.diff" ] && [ "$(cat "$T/out-empty/snap/docs/manual/a.md")" = a1 ] && [ "$(j .diffBytes)" = 0 ]'

# --- S7: the codex deny carries over to the snapshot --------------------------------
chk "S7 an unmarked repo: no .codex-deny in the out dir, codexDenied false" '[ ! -e "$O/.codex-deny" ] && [ "$(man .codexDenied)" = false ]'
M="$T/marked/repo"
git -c init.defaultBranch=main init -q "$M"
git -C "$M" config user.email rs@localhost; git -C "$M" config user.name rs
mkdir -p "$M/docs"; printf 'x\n' > "$M/docs/x.md"
git -C "$M" add -A && git -C "$M" commit -qm one
: > "$T/marked/.codex-deny"
run_rs snapshot --repo "$M" --base HEAD --head HEAD --include 'docs/**' --out "$T/out-marked"
chk "S7b a repo under a .codex-deny marker: the out dir gets .codex-deny (ext-run.sh then refuses the snapshot for codex)" \
  '[ "$RC" -eq 0 ] && [ -f "$T/out-marked/.codex-deny" ] && [ "$(j .codexDenied)" = true ]'
printf 'review this\n' > "$T/brief.txt"
OUT=$(AGY_BOUNDARY_CLEARED=1 CODEX_BIN=/nonexistent "$REPO_DIR/scripts/ext-run.sh" read --prompt-file "$T/brief.txt" --input-dir "$T/out-marked/snap" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
chk "S7b2 ...and ext-run.sh really refuses that snapshot for codex (--input-dir: exit 3, names the marker)" '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny"'
OUT=$(AGY_BOUNDARY_CLEARED=1 CODEX_BIN=/nonexistent "$REPO_DIR/scripts/ext-run.sh" read --prompt-file "$T/brief.txt" --input "$T/out-marked/range.diff" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
chk "S7b3 ...and its range.diff (--input: exit 3)" '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny"'
M2="$T/m2/repo"
git -c init.defaultBranch=main init -q "$M2"
git -C "$M2" config user.email rs@localhost; git -C "$M2" config user.name rs
mkdir -p "$M2/docs/private"; printf 'x\n' > "$M2/docs/x.md"; : > "$M2/docs/private/.codex-deny"
git -C "$M2" add -A && git -C "$M2" commit -qm one
run_rs snapshot --repo "$M2" --base HEAD --head HEAD --include 'docs/**' --out "$T/out-m2"
chk "S7c a .codex-deny marker anywhere INSIDE the repo carries over too" '[ "$RC" -eq 0 ] && [ -f "$T/out-m2/.codex-deny" ]'
CC="$T/cc/clip-creator"
git -c init.defaultBranch=main init -q "$CC"
git -C "$CC" config user.email rs@localhost; git -C "$CC" config user.name rs
mkdir -p "$CC/docs"; printf 'x\n' > "$CC/docs/x.md"
git -C "$CC" add -A && git -C "$CC" commit -qm one
run_rs snapshot --repo "$CC" --base HEAD --head HEAD --include 'docs/**' --out "$T/out-cc"
chk "S7d a hard-denied repo (clip-creator) snapshots for Claude but carries .codex-deny" '[ "$RC" -eq 0 ] && [ -f "$T/out-cc/.codex-deny" ]'
chk "S7e HARD_DENY_REPOS matches ext-run.sh (the owner of deny decisions)" \
  '[ "$(sed -n "s/^HARD_DENY_REPOS=//p" "$RS")" = "$(sed -n "s/^HARD_DENY_REPOS=//p" "$REPO_DIR/scripts/ext-run.sh")" ]'

# --- F*: fingerprint + compare ---------------------------------------------------------
FP="$T/fp"; mkdir -p "$FP"
fp() { run_rs fingerprint --repo "$R" --path 'docs/manual/**/*.md' review/RUBRIC.md --out "$FP/$1.json"; }
cmpfp() { run_rs compare "$FP/$1.json" "$FP/$2.json"; }
fp before
chk "F1 fingerprint prints {step, head, paths, status, tree, committed} and writes it to --out" \
  '[ "$RC" -eq 0 ] && [ "$(j .step)" = fingerprint ] && [ "$(j .head)" = "$HEAD_BEFORE" ] && [ "$(jq -c .paths "$FP/before.json")" = "[\"docs/manual/**/*.md\",\"review/RUBRIC.md\"]" ] &&
   [ -n "$(j .tree)" ] && [ -n "$(j .committed)" ] && [ "$(jq -r .tree "$FP/before.json")" = "$(j .tree)" ]'
chk "F1b status is limited to the paths (the live a.md edit and untracked.md; nothing from docs/PROJECT_MEMORY.md)" \
  '[ "$(j .status)" = "$(printf " M docs/manual/a.md\n?? docs/manual/untracked.md")" ]'
printf 'outside\n' >> "$R/tools/x.py"; printf 'outside\n' > "$R/site/new.md"
fp outside
cmpfp before outside
chk "F2 a change OUTSIDE the paths is not a change (compare exit 0, same true)" '[ "$RC" -eq 0 ] && [ "$(j .same)" = true ]'
printf 'PM-EDIT\n' >> "$R/docs/manual/context/n.md"; printf 'PM\n' >> "$R/docs/PROJECT_MEMORY.md"
fp hard
cmpfp before hard
chk "F2b a change to a hard-excluded path under the paths is not a change either" '[ "$RC" -eq 0 ]'
g add tools/x.py && g commit -qm outside-commit
fp commit-outside
cmpfp before commit-outside
chk "F2c HEAD moving by a commit OUTSIDE the paths: same (exit 0), headMoved true" '[ "$RC" -eq 0 ] && [ "$(j .headMoved)" = true ] && [ "$(j .same)" = true ]'
printf 'SECOND-EDIT\n' >> "$R/docs/manual/a.md"
fp second
cmpfp before second
chk "F3 a SECOND edit to an already-dirty file under the paths is a change (exit 7: tree), status unchanged" \
  '[ "$RC" -eq 7 ] && [ "$(j .same)" = false ] && [ "$(j ".changed | join(\",\")")" = tree ] && printf "%s" "$(j .detail)" | grep -q "^SOURCE_CHANGED"'
printf 'new file\n' > "$R/docs/manual/print/added.md"
fp added
cmpfp second added
chk "F3b a new untracked file under the paths is a change (exit 7: status + tree)" '[ "$RC" -eq 7 ] && [ "$(j ".changed | join(\",\")")" = "status,tree" ]'
g add docs/manual/print/added.md && g commit -qm inside-commit
fp commit-inside
cmpfp added commit-inside
chk "F3c a commit INSIDE the paths is a change (exit 7: committed)" '[ "$RC" -eq 7 ] && printf "%s" "$(j ".changed | join(\",\")")" | grep -q committed'
printf 'not json\n' > "$FP/bad.json"
cmpfp before bad
chk "F4 compare with a file that is not a fingerprint is a usage error (exit 2)" '[ "$RC" -eq 2 ]'
run_rs compare "$FP/before.json"
chk "F4b compare needs exactly two files (exit 2)" '[ "$RC" -eq 2 ]'
run_rs fingerprint --repo "$R" --out "$FP/x.json"
chk "F4c fingerprint without --path is a usage error (exit 2)" '[ "$RC" -eq 2 ]'
run_rs frobnicate
chk "F4d an unknown subcommand is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

echo ""
echo "RESULT: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
