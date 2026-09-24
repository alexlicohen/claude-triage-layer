#!/bin/bash
# scripts/stage-worktree.sh — the staging area of a bake-off (workflows/
# triage-compare.js). Every candidate works in its OWN detached worktree of the
# caller's repo at ONE base sha, under a stage dir OUTSIDE the repo; the real
# repo is never any candidate's working directory. A candidate (or a wrapper that
# drops a flag) that writes back "to the repo" therefore lands in a throwaway
# worktree — and `leakcheck` proves afterwards that the real repo did not change.
#
# It never writes the caller's working tree or index: every read of the repo
# runs with --no-optional-locks, and the only thing it writes there is git's own
# worktree bookkeeping under .git/worktrees, which `cleanup` removes again.
#
# Usage:
#   stage-worktree.sh create    --repo R --base REV --count N --dir D
#   stage-worktree.sh diff      --worktree W --base SHA --out FILE
#   stage-worktree.sh leakcheck --repo R --dir D
#   stage-worktree.sh cleanup   --repo R --dir D
#
# create     resolves REV to a sha ONCE, records R's fingerprint (HEAD, `status
#            --porcelain=v1 -uall`, and a content manifest of every tracked +
#            untracked non-ignored path) in D, then creates N detached worktrees
#            D/wt-1..D/wt-N at that sha (hooks off). D must be absolute, outside R,
#            not containing R, and absent or empty. Prints one JSON object:
#              {"sha","worktrees":["D/wt-1",...],"fingerprint":"D/fingerprint","head","repo"}
#            (paths spelled as D was given). Any failure rolls back what it made.
# diff       `git -C W add -A` then `git -C W diff --binary --cached SHA` into FILE
#            (new, deleted, binary and modified files; FILE is removed first, so a
#            stale patch never survives a failed diff). W must be a LINKED
#            worktree — a main working tree is refused, so this can never stage
#            into the real repo's index. Prints one JSON line:
#              {"step":"diff","worktree","patch","ok":true|false,"shortstat"|"error"}
# leakcheck  compares R now with the fingerprint in D. Prints one JSON line
#              {"step":"leakcheck","status":"CLEAN|LEAK|BASE_MOVED","leak","baseMoved",
#               "sha","headBefore","headAfter","paths":[...],"detail"}
#            LEAK = with HEAD unchanged, the status or any path's content changed;
#            with HEAD moved, any path's CONTENT changed (a commit alone only moves
#            status). BASE_MOVED = HEAD moved (someone committed) and nothing else
#            changed: grading stays at the recorded sha.
# cleanup    `git worktree remove --force` each staged worktree, `git worktree
#            prune`, rm -rf D. Refuses a D with no fingerprint (not a stage dir).
#            An absent D is already clean (exit 0). Prints {"step":"cleanup","ok"}.
#
# Exit codes: 0 ok (CLEAN / BASE_MOVED for leakcheck); 1 the step failed (JSON
#             says why); 2 usage error, nothing done; 7 LEAK (leakcheck only).
set -uo pipefail
export LC_ALL=C
# Inherited git redirection (GIT_DIR & co. from a hook or a caller) would point
# every `git -C` below at another repository — -C does not override it.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES

usage() { echo "stage-worktree: USAGE: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || usage "jq is required"
command -v git >/dev/null 2>&1 || usage "git is required"

SUB="${1:-}"
[ $# -gt 0 ] && shift
REPO="" BASE="" COUNT="" DIR="" WT="" OUT=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage "$1 needs a value"
  case "$1" in
    --repo)     REPO="$2" ;;
    --base)     BASE="$2" ;;
    --count)    COUNT="$2" ;;
    --dir)      DIR="$2" ;;
    --worktree) WT="$2" ;;
    --out)      OUT="$2" ;;
    *)          usage "unknown argument $1" ;;
  esac
  shift 2
done

# phys PATH — the physical form of an absolute path that may not exist yet (the
# deepest existing ancestor is resolved with pwd -P; the rest is appended).
phys() {
  local p="$1" rest=""
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  while [ ! -d "$p" ]; do
    rest="/$(basename "$p")$rest"
    p=$(dirname "$p")
  done
  p=$(cd "$p" && pwd -P) || return 1
  [ "$p" = / ] && p=""
  printf '%s%s\n' "$p" "$rest"
}
# within A B — A is B or below it (both physical).
within() { [ "$1" = "$2" ] || case "$1" in "$2"/*) return 0 ;; *) return 1 ;; esac; }

check_abs() { # $1 flag name, $2 value
  case "$2" in /*) ;; *) usage "$1 must be an absolute path (got '$2')" ;; esac
  case "/$2/" in */../*|*/./*) usage "$1 must not contain . or .. components" ;; esac
}

repo_top() { # $1 repo path -> physical top level, or usage error
  local t
  t=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || usage "--repo is not a git work tree: $1"
  (cd "$t" && pwd -P)
}

# The stage dir must never overlap the repo in either direction: inside R it
# dirties R; containing R, cleanup's rm -rf would delete R.
check_dir_vs_repo() { # $1 physical D, $2 physical R
  within "$1" "$2" && usage "refusing: --dir $DIR is inside the repo $2"
  within "$2" "$1" && usage "refusing: --dir $DIR contains the repo $2"
  return 0
}

# snapshot R OUTFILE — "<path>\t<blob sha|link:<target>|dir|missing>" for every
# tracked + untracked non-ignored path, sorted. Content-addressed, so it does
# not depend on HEAD: committing leaves it unchanged, editing any file does not.
snapshot() {
  local r="$1" out="$2" p
  : > "$out.files"; : > "$out.other"
  while IFS= read -r -d '' p; do
    if [ -L "$r/$p" ]; then printf '%s\tlink:%s\n' "$p" "$(readlink "$r/$p")" >> "$out.other"
    elif [ -f "$r/$p" ]; then printf '%s\n' "$p" >> "$out.files"
    elif [ -d "$r/$p" ]; then printf '%s\tdir\n' "$p" >> "$out.other"
    else printf '%s\tmissing\n' "$p" >> "$out.other"
    fi
  done < <(git -C "$r" --no-optional-locks ls-files -z -c -o --exclude-standard)
  if [ -s "$out.files" ]; then
    (cd "$r" && git hash-object --no-filters --stdin-paths < "$out.files") > "$out.hashes" || return 1
  else
    : > "$out.hashes"
  fi
  [ "$(wc -l < "$out.files")" -eq "$(wc -l < "$out.hashes")" ] || return 1
  { paste "$out.files" "$out.hashes"; cat "$out.other"; } | sort -u > "$out"
  rm -f "$out.files" "$out.other" "$out.hashes"
}

status_of() { git -C "$1" --no-optional-locks status --porcelain=v1 -uall; }
fp_get() { sed -n "s/^$1=//p" "$2" | head -n 1; }

# ---------------------------------------------------------------------------
do_create() {
  [ -n "$REPO" ] && [ -n "$BASE" ] && [ -n "$COUNT" ] && [ -n "$DIR" ] || usage "create needs --repo --base --count --dir"
  case "$COUNT" in ''|*[!0-9]*) usage "--count must be a positive integer" ;; esac
  [ "$COUNT" -ge 1 ] || usage "--count must be a positive integer"
  check_abs --dir "$DIR"
  local R D DL SHA HEAD i made=""
  R=$(repo_top "$REPO")
  SHA=$(git -C "$R" rev-parse --verify --quiet "$BASE^{commit}") || usage "--base does not name a commit in $R: $BASE"
  HEAD=$(git -C "$R" rev-parse --verify --quiet HEAD) || HEAD=""
  D=$(phys "$DIR") || usage "could not resolve --dir $DIR"
  DL="$DIR"; while [ "${#DL}" -gt 1 ] && [ "${DL%/}" != "$DL" ]; do DL="${DL%/}"; done
  check_dir_vs_repo "$D" "$R"
  if [ -e "$D" ]; then
    [ -d "$D" ] && [ -z "$(ls -A "$D")" ] || usage "--dir $DIR exists and is not empty (a previous stage? run: stage-worktree.sh cleanup --repo $REPO --dir $DIR)"
  fi
  mkdir -p "$D" || usage "could not create --dir $DIR"

  rollback() {
    local w
    for w in $made; do git -C "$R" worktree remove --force --force "$w" >/dev/null 2>&1; done
    git -C "$R" worktree prune >/dev/null 2>&1
    rm -rf "$D"
  }
  # Fingerprint FIRST: it is the state before any candidate ran.
  {
    printf 'repo=%s\nsha=%s\nhead=%s\ncount=%s\nbase=%s\n' "$R" "$SHA" "$HEAD" "$COUNT" "$BASE"
  } > "$D/fingerprint"
  status_of "$R" > "$D/fingerprint.status" 2>/dev/null || { rollback; echo "stage-worktree: could not read the status of $R" >&2; exit 1; }
  snapshot "$R" "$D/fingerprint.tree" || { rollback; echo "stage-worktree: could not snapshot $R" >&2; exit 1; }

  i=1
  while [ "$i" -le "$COUNT" ]; do
    if ! git -C "$R" -c core.hooksPath=/dev/null worktree add --detach "$D/wt-$i" "$SHA" > "$D/create.log" 2>&1; then
      echo "stage-worktree: could not create worktree $i at $SHA: $(head -c 400 "$D/create.log")" >&2
      rollback; exit 1
    fi
    made="$made $D/wt-$i"
    i=$((i + 1))
  done
  rm -f "$D/create.log"

  local list=()
  i=1
  while [ "$i" -le "$COUNT" ]; do list+=("$DL/wt-$i"); i=$((i + 1)); done
  jq -nc --arg sha "$SHA" --arg head "$HEAD" --arg repo "$R" --arg fp "$DL/fingerprint" \
    '{sha:$sha, worktrees:$ARGS.positional, fingerprint:$fp, head:$head, repo:$repo}' --args "${list[@]}"
}

# ---------------------------------------------------------------------------
diff_fail() { # $1 message
  jq -nc --arg w "$WT" --arg p "$OUT" --arg e "$1" '{step:"diff", worktree:$w, patch:$p, ok:false, error:$e}'
  exit 1
}
do_diff() {
  [ -n "$WT" ] && [ -n "$BASE" ] && [ -n "$OUT" ] || usage "diff needs --worktree --base --out"
  check_abs --worktree "$WT"
  check_abs --out "$OUT"
  rm -f "$OUT"   # a stale patch from an earlier run must never survive a failed diff
  [ -d "$WT" ] || diff_fail "worktree does not exist: $WT"
  local top wp gd cd SHA
  top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) || diff_fail "not a git worktree: $WT"
  top=$(cd "$top" && pwd -P); wp=$(cd "$WT" && pwd -P)
  [ "$top" = "$wp" ] || diff_fail "not the root of a worktree: $WT"
  gd=$(cd "$WT" && cd "$(git rev-parse --git-dir)" && pwd -P)
  cd=$(cd "$WT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  [ "$gd" != "$cd" ] || diff_fail "refusing: $WT is a main working tree, not a staged (linked) worktree"
  SHA=$(git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}") || diff_fail "--base does not name a commit: $BASE"
  mkdir -p "$(dirname "$OUT")" || diff_fail "could not create the directory of $OUT"
  git -C "$WT" add -A >/dev/null 2>&1 || diff_fail "git add -A failed in $WT"
  git -C "$WT" diff --binary --cached "$SHA" > "$OUT.tmp" 2>/dev/null || { rm -f "$OUT.tmp"; diff_fail "git diff failed in $WT"; }
  mv "$OUT.tmp" "$OUT" || diff_fail "could not write $OUT"
  local stat
  stat=$(git -C "$WT" diff --cached --shortstat "$SHA" 2>/dev/null | sed 's/^ *//')
  jq -nc --arg w "$WT" --arg p "$OUT" --arg s "$stat" '{step:"diff", worktree:$w, patch:$p, ok:true, shortstat:$s}'
}

# ---------------------------------------------------------------------------
stage_paths() { # sets R, D from --repo/--dir; refuses overlap
  [ -n "$REPO" ] && [ -n "$DIR" ] || usage "$SUB needs --repo --dir"
  check_abs --dir "$DIR"
  R=$(repo_top "$REPO")
  D=$(phys "$DIR") || usage "could not resolve --dir $DIR"
  check_dir_vs_repo "$D" "$R"
}

do_leakcheck() {
  local R D
  stage_paths
  [ -f "$D/fingerprint" ] && [ -f "$D/fingerprint.tree" ] && [ -f "$D/fingerprint.status" ] || usage "no fingerprint in $DIR (run create first)"
  [ "$(fp_get repo "$D/fingerprint")" = "$R" ] || usage "the fingerprint in $DIR was taken of $(fp_get repo "$D/fingerprint"), not $R"
  local sha h0 h1 tree_same=1 status_same=1 status leak=false moved=false commits=0 detail
  sha=$(fp_get sha "$D/fingerprint"); h0=$(fp_get head "$D/fingerprint")
  h1=$(git -C "$R" rev-parse --verify --quiet HEAD) || h1=""
  snapshot "$R" "$D/now.tree" || { echo "stage-worktree: could not snapshot $R" >&2; exit 1; }
  status_of "$R" > "$D/now.status" 2>/dev/null || { echo "stage-worktree: could not read the status of $R" >&2; exit 1; }
  cmp -s "$D/fingerprint.tree" "$D/now.tree" || tree_same=0
  cmp -s "$D/fingerprint.status" "$D/now.status" || status_same=0

  # The paths that differ: content changes first, then status-only changes.
  { diff "$D/fingerprint.tree" "$D/now.tree" | sed -n 's/^[<>] //p' | cut -f1
    diff "$D/fingerprint.status" "$D/now.status" | sed -n 's/^[<>] ...//p'
  } | sort -u > "$D/now.paths"
  rm -f "$D/now.tree" "$D/now.status"

  if [ "$h1" != "$h0" ]; then
    moved=true
    commits=$(git -C "$R" rev-list --count "$h0..$h1" 2>/dev/null || echo 0)
  fi
  if [ "$moved" = false ] && { [ "$tree_same" -eq 0 ] || [ "$status_same" -eq 0 ]; }; then leak=true
  elif [ "$moved" = true ] && [ "$tree_same" -eq 0 ]; then leak=true
  fi

  local n shown
  n=$(wc -l < "$D/now.paths" | tr -d ' ')
  shown=$(head -n 10 "$D/now.paths" | paste -sd, - | sed 's/,/, /g')
  if [ "$leak" = true ]; then
    status=LEAK
    detail="LEAK: the real repo $R changed while the candidates ran — $n path(s): $shown. Inspect it before anything else; nothing here reverts it."
  elif [ "$moved" = true ]; then
    status=BASE_MOVED
    detail="BASE_MOVED: HEAD of $R moved ${h0:0:12}..${h1:0:12} ($commits commit(s)) during the run and nothing else changed; grading stays at ${sha:0:12}."
  else
    status=CLEAN
    detail="CLEAN: $R is unchanged."
  fi
  echo "stage-worktree: $detail" >&2
  jq -nc --arg st "$status" --argjson leak "$leak" --argjson moved "$moved" --arg sha "$sha" \
    --arg h0 "$h0" --arg h1 "$h1" --rawfile paths "$D/now.paths" --arg d "$detail" \
    '{step:"leakcheck", status:$st, leak:$leak, baseMoved:$moved, sha:$sha, headBefore:$h0, headAfter:$h1,
      paths:($paths | split("\n") | map(select(length > 0))), detail:$d}'
  rm -f "$D/now.paths"
  [ "$leak" = true ] && exit 7
  exit 0
}

do_cleanup() {
  local R D
  stage_paths
  if [ ! -e "$D" ]; then jq -nc '{step:"cleanup", ok:true, removed:0}'; exit 0; fi
  [ -f "$D/fingerprint" ] || usage "refusing: $DIR has no fingerprint — not a stage dir, nothing removed"
  [ "$(fp_get repo "$D/fingerprint")" = "$R" ] || usage "the stage in $DIR belongs to $(fp_get repo "$D/fingerprint"), not $R"
  local n i removed=0
  n=$(fp_get count "$D/fingerprint")
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  i=1
  while [ "$i" -le "$n" ]; do
    if [ -e "$D/wt-$i" ]; then
      git -C "$R" worktree remove --force --force "$D/wt-$i" >/dev/null 2>&1
      rm -rf "$D/wt-$i"
      removed=$((removed + 1))
    fi
    i=$((i + 1))
  done
  git -C "$R" worktree prune >/dev/null 2>&1
  rm -rf "$D"
  if [ -e "$D" ] || git -C "$R" worktree list --porcelain | grep -qF "worktree $D/"; then
    jq -nc --arg d "$DIR" '{step:"cleanup", ok:false, error:("staged worktrees remain under " + $d)}'
    exit 1
  fi
  jq -nc --argjson n "$removed" '{step:"cleanup", ok:true, removed:$n}'
}

case "$SUB" in
  create)    do_create ;;
  diff)      do_diff ;;
  leakcheck) do_leakcheck ;;
  cleanup)   do_cleanup ;;
  *)         usage "stage-worktree.sh create|diff|leakcheck|cleanup [options] (see the header)" ;;
esac
