#!/bin/bash
# scripts/review-stage.sh — the staging area of a REVIEW bake-off (workflows/
# triage-compare.js, kind:'review'). Reviewers never see the live repo: they get a
# snapshot of ONE commit, filtered to the paths under review plus their context,
# and the range diff — both written under an out dir OUTSIDE the repo.
#
# Usage:
#   review-stage.sh snapshot    --repo R --base B --head H --include GLOB... [--exclude GLOB...]
#                               [--context PATH...] [--extra SRC:DEST...] [--hard-exclude PATTERN...]
#                               --out DIR
#   review-stage.sh fingerprint --repo R --path P... [--hard-exclude PATTERN...] [--out FILE]
#   review-stage.sh compare     A.json B.json
#
# A multi-value flag takes every following argument up to the next --flag, and may
# be repeated. GLOB/PATH/P are git pathspecs with :(glob) magic, relative to the
# repo root: `*` stays inside one directory, `**/` spans any depth (docs/**/*.md
# matches docs/a.md too), a directory matches everything below it. No leading /,
# -, or :, no . or .. components.
#
# snapshot   resolves B and H to shas, then writes into DIR (absolute, outside R,
#            not containing R, absent or empty):
#              DIR/snap          the files of commit H (`git archive H`, never the
#                                live tree, no .git) selected as (include minus
#                                exclude) plus context; symlinks and submodules
#                                are dropped. Each --extra SRC (an absolute
#                                regular file OUTSIDE R, e.g. a cache file) is
#                                copied to DIR/snap/_extra/DEST.
#              DIR/range.diff    `git diff B H -- <include minus exclude>` (no
#                                renames, no external diff/textconv, a/ b/ prefixes).
#              DIR/manifest.json {base, head, baseRef, headRef, include, exclude,
#                                context, hardExclude, files:[{path,bytes}],
#                                extras:[{src,dest,bytes}], excluded:[{path,reason,
#                                pattern?}], codexDenied}
#            HARD EXCLUDES are applied to everything written into DIR, whether a
#            path is tracked, ignored or untracked, and whatever --include or
#            --context name: the defaults `context/` and `PROJECT_MEMORY*.md` plus
#            each --hard-exclude. Pattern semantics are gitignore's, erring wide: a
#            pattern with no inner slash matches ANY path component (context/ drops
#            docs/context/x too); one with a slash is anchored at the repo root and
#            its * may cross directories. A hard-excluded path is never archived,
#            never in range.diff, and is listed in manifest.excluded. An --extra
#            whose DEST, or any component of whose SRC, a hard exclude matches is
#            refused (exit 2).
#            DENY CARRIES OVER: when R (or its main worktree) or an --extra SRC is
#            under a hard-denied repo (clip-creator) or a .codex-deny marker lies
#            on its way up to $HOME, DIR/.codex-deny is written, so ext-run.sh
#            refuses the snapshot and the diff for codex exactly as it would the
#            repo (Claude may still read them). stdout: one JSON line
#              {"step":"snapshot","ok":true,"base","head","snap","diff","manifest",
#               "files","bytes","diffBytes","extras","excluded","codexDenied"}
#            A failure removes what this run wrote.
# fingerprint  the SOURCE-CHANGED guard of a review: prints (and with --out also
#            writes to FILE) one JSON line
#              {"step":"fingerprint","head","paths":[P...],"status","tree","committed"}
#            status = `git status --porcelain=v1 -uall --no-renames -- <paths>`,
#            tree = a hash over the content of every changed/untracked path in it
#            (a second edit to an already-dirty file changes it), committed = a
#            hash over HEAD's blobs at <paths>. Hard-excluded paths are left out
#            of all three. Read-only (--no-optional-locks).
# compare    exit 0 when A and B have the same status, tree and committed hash, 7
#            when any differs (a commit, edit or new file INSIDE the paths); a
#            change outside the paths, or HEAD moving by a commit outside them,
#            is not a change. Prints {"step":"compare","same","changed":[...],
#            "headMoved","detail"}.
#
# Exit codes: 0 ok / same; 1 the step failed; 2 usage error, nothing written;
#             7 compare: changed.
set -uo pipefail
export LC_ALL=C
# Inherited git redirection (GIT_DIR & co. from a hook or a caller) would point
# every `git -C` below at another repository — -C does not override it.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES

# Mirrors HARD_DENY_REPOS in ext-run.sh (the owner of deny decisions);
# test/review-stage.sh fails if the two ever differ.
HARD_DENY_REPOS="clip-creator"
TAB=$(printf '\t')
NL='
'

die() { echo "review-stage: $1" >&2; exit "${2:-1}"; }
usage() { die "USAGE: $1" 2; }
command -v jq >/dev/null 2>&1 || usage "jq is required"
command -v git >/dev/null 2>&1 || usage "git is required"

SUB="${1:-}"
[ $# -gt 0 ] && shift
REPO="" BASE="" HEAD_REF="" OUT="" FP_OUT=""
INCLUDES=() EXCLUDES=() CONTEXTS=() EXTRAS=() HARD=() PATHS=() POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --include|--exclude|--context|--extra|--hard-exclude|--path)
      flag="$1"; shift
      [ $# -gt 0 ] && case "$1" in --*) false ;; *) true ;; esac || usage "$flag needs a value"
      while [ $# -gt 0 ]; do
        case "$1" in --*) break ;; esac
        case "$flag" in
          --include)      INCLUDES+=("$1") ;;
          --exclude)      EXCLUDES+=("$1") ;;
          --context)      CONTEXTS+=("$1") ;;
          --extra)        EXTRAS+=("$1") ;;
          --hard-exclude) HARD+=("$1") ;;
          --path)         PATHS+=("$1") ;;
        esac
        shift
      done
      continue ;;
    --repo|--base|--head|--out)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case "$1" in
        --repo) REPO="$2" ;;
        --base) BASE="$2" ;;
        --head) HEAD_REF="$2" ;;
        --out)  OUT="$2" ;;
      esac
      shift 2 ;;
    --*) usage "unknown argument $1" ;;
    *) POS+=("$1"); shift ;;
  esac
done
# The default hard excludes come first, always (quoted: never glob-expanded).
HARD=("context/" "PROJECT_MEMORY*.md" ${HARD+"${HARD[@]}"})

# phys PATH — the physical form of an absolute path that may not exist yet.
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
within() { [ "$1" = "$2" ] || case "$1" in "$2"/*) return 0 ;; *) return 1 ;; esac; }
HOME_P=$(cd "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_P="${HOME:-/}"

check_abs() { # $1 flag name, $2 value
  case "$2" in /*) ;; *) usage "$1 must be an absolute path (got '$2')" ;; esac
  case "/$2/" in */../*|*/./*) usage "$1 must not contain . or .. components" ;; esac
  case "$2" in *"$NL"*) usage "$1 must not contain a newline" ;; esac
}
check_glob() { # $1 flag name, $2 pattern — a repo-relative pattern
  case "$2" in ''|/*|-*|:*) usage "$1 '$2' must be a non-empty path relative to the repo root (no leading /, - or :)" ;; esac
  case "/$2/" in */../*|*/./*) usage "$1 '$2' must not contain . or .. components" ;; esac
  case "$2" in *"$NL"*|*"$TAB"*) usage "$1 must not contain a newline or a tab" ;; esac
}
repo_top() { # $1 repo path -> physical top level, or usage error
  local t
  t=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || usage "--repo is not a git work tree: $1"
  (cd "$t" && pwd -P)
}
# The empty tree, in this repository's hash format (sha1 or sha256).
empty_tree() { git -C "$1" hash-object -t tree /dev/null; }

# ---------------------------------------------------------------------------
# hard_match REL — SINGLE OWNER of the hard-exclude decision. Prints the pattern
# that matches the repo-relative path REL (rc 0), or nothing (rc 1). gitignore
# semantics, erring wide (see the header).
hard_match() {
  local rel="$1" pat p c anchored rest
  for pat in "${HARD[@]}"; do
    p="$pat"; anchored=0
    case "$p" in /*) anchored=1; p="${p#/}" ;; esac
    p="${p%/}"
    case "$p" in */*) anchored=1 ;; esac
    [ -n "$p" ] || continue
    if [ "$anchored" -eq 1 ]; then
      # shellcheck disable=SC2254  # $p is a glob pattern on purpose
      case "$rel" in $p|$p/*) printf '%s\n' "$pat"; return 0 ;; esac
    else
      rest="$rel"
      while [ -n "$rest" ]; do
        c="${rest%%/*}"
        # shellcheck disable=SC2254  # $p is a glob pattern on purpose
        case "$c" in $p) printf '%s\n' "$pat"; return 0 ;; esac
        case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
      done
    fi
  done
  return 1
}
# split_hard IN KEEP DROP — each line of IN (TAB-separated fields, the path LAST)
# goes to KEEP, or to DROP as "<path><TAB><pattern>" when a hard exclude matches
# its path. Tracked or not, included or context, it makes no difference here.
split_hard() {
  local line rel pat
  : > "$2"; : > "$3"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rel="${line##*"$TAB"}"
    if pat=$(hard_match "$rel"); then printf '%s\t%s\n' "$rel" "$pat" >> "$3"; continue; fi
    printf '%s\n' "$line" >> "$2"
  done < "$1"
}

# deny_marked PATH — rc 0 when PATH has a hard-denied repo name as a component, or
# a .codex-deny marker in PATH (a dir) or any directory above it up to AND
# INCLUDING $HOME (or /). Mirrors ext-run.sh deny_check_path; used only to carry
# the deny over to the snapshot (ext-run.sh stays the owner of every refusal).
deny_marked() {
  local p="$1" d name
  for name in $HARD_DENY_REPOS; do
    case "/$p/" in */"$name"/*) return 0 ;; esac
  done
  d="$p"
  [ -d "$d" ] || d=$(dirname "$d")
  while [ -n "$d" ]; do
    [ -f "$d/.codex-deny" ] && return 0
    case "$d" in /|"${HOME:-/}"|"$HOME_P") break ;; esac
    [ "$(dirname "$d")" != "$d" ] || break
    d=$(dirname "$d")
  done
  return 1
}
# deny_beneath DIR — rc 0 when a .codex-deny marker or a hard-denied repo name
# lies anywhere below DIR (.git skipped): part of DIR may be off-limits to codex.
deny_beneath() {
  local name
  set -- "$1" -name .codex-deny
  for name in $HARD_DENY_REPOS; do set -- "$@" -o -name "$name"; done
  [ -n "$(find "$1" -name .git -prune -o \( "${@:2}" \) -print 2>/dev/null | head -n 1)" ]
}
main_worktree_of() { # the main worktree of the repo PATH belongs to, physical
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] || return 0
  common=$(cd "$common" 2>/dev/null && pwd -P) || return 0
  case "$common" in */.git) dirname "$common" ;; *) printf '%s\n' "$common" ;; esac
}

# pathspecs MAGIC GLOB... — prints one :(MAGIC)GLOB per line.
pathspecs() {
  local m="$1" g
  shift
  for g in "$@"; do printf ':(%s)%s\n' "$m" "${g%/}"; done
}
# list_raw REPO FROM TO OUT SPEC-FILE — "<new mode><TAB><new sha><TAB><path>" for
# every path that differs between FROM and TO under the pathspecs in SPEC-FILE (one
# per line), sorted by path. Against the empty tree that is every path of TO. A path with a newline
# or a tab is refused (nothing downstream could keep it apart).
list_raw() {
  local r="$1" from="$2" to="$3" out="$4" meta path
  local specs=()
  while IFS= read -r meta; do specs+=("$meta"); done < "$5"
  : > "$out.tmp"
  git -C "$r" -c core.quotePath=false diff --raw -z --no-abbrev --no-renames --no-ext-diff --no-textconv \
      "$from" "$to" -- "${specs[@]}" > "$out.z" 2>"$out.err" || { rm -f "$out.z" "$out.tmp"; return 1; }
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    case "$path" in *"$NL"*|*"$TAB"*) echo "review-stage: a path contains a newline or a tab — refusing: $(printf '%q' "$path")" >&2; rm -f "$out.z" "$out.tmp"; return 1 ;; esac
    # meta = ":<old mode> <new mode> <old sha> <new sha> <status>"
    # shellcheck disable=SC2086  # split into its five fields on purpose (no glob characters)
    set -- $meta
    printf '%s\t%s\t%s\n' "$2" "$4" "$path" >> "$out.tmp"
  done < "$out.z"
  sort -t "$TAB" -k3,3 -u "$out.tmp" > "$out"
  rm -f "$out.z" "$out.tmp" "$out.err"
}

# ---------------------------------------------------------------------------
do_snapshot() {
  [ -n "$REPO" ] && [ -n "$BASE" ] && [ -n "$HEAD_REF" ] && [ -n "$OUT" ] || usage "snapshot needs --repo --base --head --include --out"
  [ ${#INCLUDES[@]} -gt 0 ] || usage "snapshot needs at least one --include"
  [ ${#POS[@]} -eq 0 ] || usage "unexpected argument ${POS[0]}"
  local g x
  for g in "${INCLUDES[@]}"; do check_glob --include "$g"; done
  for g in ${EXCLUDES+"${EXCLUDES[@]}"}; do check_glob --exclude "$g"; done
  for g in ${CONTEXTS+"${CONTEXTS[@]}"}; do check_glob --context "$g"; done
  for g in "${HARD[@]}"; do case "$g" in ''|*"$NL"*) usage "--hard-exclude must be a non-empty single-line pattern" ;; esac; done
  check_abs --out "$OUT"
  local R D B H EMPTY created=0 codex_denied=false main
  R=$(repo_top "$REPO")
  B=$(git -C "$R" rev-parse --verify --quiet "$BASE^{commit}") || usage "--base does not name a commit in $R: $BASE"
  H=$(git -C "$R" rev-parse --verify --quiet "$HEAD_REF^{commit}") || usage "--head does not name a commit in $R: $HEAD_REF"
  D=$(phys "$OUT") || usage "could not resolve --out $OUT"
  within "$D" "$R" && usage "refusing: --out $OUT is inside the repo $R"
  within "$R" "$D" && usage "refusing: --out $OUT contains the repo $R"
  if [ -e "$D" ]; then
    [ -d "$D" ] && [ -z "$(ls -A "$D")" ] || usage "--out $OUT exists and is not empty (a review stage must be fresh)"
  fi

  # --extra SRC:DEST — validated before anything is written.
  local ex src dest srcp comp extras_tsv=""
  for ex in ${EXTRAS+"${EXTRAS[@]}"}; do
    case "$ex" in *:*) ;; *) usage "--extra must be SRC:DEST (got '$ex')" ;; esac
    src="${ex%:*}"; dest="${ex##*:}"
    check_abs "--extra SRC" "$src"
    check_glob "--extra DEST" "$dest"
    [ -f "$src" ] && [ ! -L "$src" ] || usage "--extra SRC must be an existing regular file, not a link or a directory: $src"
    srcp=$(phys "$src") || usage "could not resolve --extra $src"
    within "$srcp" "$R" && usage "refusing: --extra $src is inside the repo — repo content comes only from commit $HEAD_REF"
    within "$srcp" "$D" && usage "refusing: --extra $src is inside --out"
    x=$(hard_match "$dest") && usage "refusing: --extra DEST $dest matches the hard exclude '$x'"
    comp="${srcp#/}"
    x=$(hard_match "$comp") && usage "refusing: --extra $src matches the hard exclude '$x' (a component of its path)"
    deny_marked "$srcp" && codex_denied=true
    extras_tsv="$extras_tsv$srcp$TAB$dest$NL"
  done
  if deny_marked "$R" || deny_beneath "$R"; then codex_denied=true; fi
  main=$(main_worktree_of "$R")
  if [ -n "$main" ] && [ "$main" != "$R" ] && deny_marked "$main"; then codex_denied=true; fi

  [ -e "$D" ] || { mkdir -p "$D" || usage "could not create --out $OUT"; created=1; }
  local W="$D/.review-stage.tmp"
  mkdir -p "$W" || die "could not create $W"
  rollback() {
    rm -rf "$W" "$D/snap" "$D/range.diff" "$D/manifest.json" "$D/.codex-deny"
    [ "$created" -eq 1 ] && rmdir "$D" 2>/dev/null
    return 0
  }
  EMPTY=$(empty_tree "$R")

  # Selection: (include minus exclude) plus context, from commit H.
  { pathspecs glob "${INCLUDES[@]}"; [ ${#EXCLUDES[@]} -gt 0 ] && pathspecs glob,exclude "${EXCLUDES[@]}"; } > "$W/inc.spec"
  list_raw "$R" "$EMPTY" "$H" "$W/inc" "$W/inc.spec" || { rollback; die "could not list the included paths of $H"; }
  : > "$W/ctx"
  if [ ${#CONTEXTS[@]} -gt 0 ]; then
    pathspecs glob "${CONTEXTS[@]}" > "$W/ctx.spec"
    list_raw "$R" "$EMPTY" "$H" "$W/ctx" "$W/ctx.spec" || { rollback; die "could not list the context paths of $H"; }
  fi
  sort -t "$TAB" -k3,3 -u "$W/inc" "$W/ctx" > "$W/sel"
  split_hard "$W/sel" "$W/sel.keep" "$W/sel.drop"
  : > "$W/files"; : > "$W/other"
  local mode path
  while IFS="$TAB" read -r mode _ path; do
    case "$mode" in
      100644|100755) printf '%s\n' "$path" >> "$W/files" ;;
      120000) printf '%s\tsymlink\n' "$path" >> "$W/other" ;;
      160000) printf '%s\tsubmodule\n' "$path" >> "$W/other" ;;
      *) printf '%s\tmode-%s\n' "$path" "$mode" >> "$W/other" ;;
    esac
  done < "$W/sel.keep"

  # The archive of H — never the live tree. Literal pathspecs, in chunks (ARG_MAX).
  mkdir -p "$D/snap" || { rollback; die "could not create $D/snap"; }
  local chunk=()
  flush() {
    [ ${#chunk[@]} -gt 0 ] || return 0
    GIT_LITERAL_PATHSPECS=1 git -C "$R" -c core.autocrlf=false archive --format=tar "$H" -- "${chunk[@]}" 2>>"$W/archive.err" |
      tar -xf - -C "$D/snap" 2>>"$W/archive.err" || return 1
    chunk=()
  }
  while IFS= read -r path; do
    chunk+=("$path")
    if [ ${#chunk[@]} -ge 100 ]; then flush || { rollback; die "git archive of $H failed: $(head -c 300 "$W/archive.err")"; }; fi
  done < "$W/files"
  flush || { rollback; die "git archive of $H failed: $(head -c 300 "$W/archive.err")"; }
  # Every selected file must have landed (an export-ignore attribute in H would
  # drop one silently): fail loud rather than hand reviewers a partial snapshot.
  : > "$W/files.tsv"
  while IFS= read -r path; do
    [ -f "$D/snap/$path" ] && [ ! -L "$D/snap/$path" ] || { rollback; die "git archive did not produce $path (an export-ignore attribute in $H?)"; }
    printf '%s\t%s\n' "$path" "$(wc -c < "$D/snap/$path" | tr -d ' ')" >> "$W/files.tsv"
  done < "$W/files"

  # Extras.
  : > "$W/extras.tsv"
  if [ -n "$extras_tsv" ]; then
    while IFS="$TAB" read -r srcp dest; do
      [ -n "$srcp" ] || continue
      [ ! -e "$D/snap/_extra/$dest" ] || { rollback; usage "--extra DEST _extra/$dest collides with another extra or a snapshot path"; }
      mkdir -p "$(dirname "$D/snap/_extra/$dest")" && cp "$srcp" "$D/snap/_extra/$dest" || { rollback; die "could not copy --extra $srcp"; }
      printf '%s\t%s\t%s\n' "$srcp" "$dest" "$(wc -c < "$D/snap/_extra/$dest" | tr -d ' ')" >> "$W/extras.tsv"
    done <<EOF
$extras_tsv
EOF
  fi

  # range.diff: B..H under (include minus exclude), minus the hard excludes.
  list_raw "$R" "$B" "$H" "$W/rng" "$W/inc.spec" || { rollback; die "could not list the paths changed in $BASE..$HEAD_REF"; }
  split_hard "$W/rng" "$W/rng.keep" "$W/rng.drop"
  : > "$D/range.diff"
  chunk=()
  flushdiff() {
    [ ${#chunk[@]} -gt 0 ] || return 0
    GIT_LITERAL_PATHSPECS=1 git -C "$R" -c core.quotePath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.relative=false \
      diff --no-color --no-renames --no-ext-diff --no-textconv -U3 --src-prefix=a/ --dst-prefix=b/ "$B" "$H" -- "${chunk[@]}" >> "$D/range.diff" 2>>"$W/diff.err" || return 1
    chunk=()
  }
  while IFS="$TAB" read -r _ _ path; do
    chunk+=("$path")
    if [ ${#chunk[@]} -ge 100 ]; then flushdiff || { rollback; die "git diff failed: $(head -c 300 "$W/diff.err")"; }; fi
  done < "$W/rng.keep"
  flushdiff || { rollback; die "git diff failed: $(head -c 300 "$W/diff.err")"; }

  [ "$codex_denied" = true ] && : > "$D/.codex-deny"

  # Manifest + summary.
  { cut -f1,2 "$W/sel.drop" | sed "s/$TAB/${TAB}hard-exclude$TAB/"; cut -f1,2 "$W/rng.drop" | sed "s/$TAB/${TAB}hard-exclude$TAB/"; cat "$W/other"; } |
    sort -t "$TAB" -k1,1 -u > "$W/excluded.tsv"
  list_json() { jq -R -s -c "$1" "$2"; }
  jq -n -c \
    --arg base "$B" --arg head "$H" --arg baseRef "$BASE" --arg headRef "$HEAD_REF" \
    --argjson include "$(printf '%s\n' "${INCLUDES[@]}" | list_json 'split("\n") | map(select(length > 0))' /dev/stdin)" \
    --argjson exclude "$(printf '%s\n' ${EXCLUDES+"${EXCLUDES[@]}"} | list_json 'split("\n") | map(select(length > 0))' /dev/stdin)" \
    --argjson context "$(printf '%s\n' ${CONTEXTS+"${CONTEXTS[@]}"} | list_json 'split("\n") | map(select(length > 0))' /dev/stdin)" \
    --argjson hard "$(printf '%s\n' "${HARD[@]}" | list_json 'split("\n") | map(select(length > 0))' /dev/stdin)" \
    --argjson files "$(list_json 'split("\n") | map(select(length > 0) | split("\t") | {path: .[0], bytes: (.[1] | tonumber)})' "$W/files.tsv")" \
    --argjson extras "$(list_json 'split("\n") | map(select(length > 0) | split("\t") | {src: .[0], dest: ("_extra/" + .[1]), bytes: (.[2] | tonumber)})' "$W/extras.tsv")" \
    --argjson excluded "$(list_json 'split("\n") | map(select(length > 0) | split("\t") | {path: .[0], reason: .[1]} + (if (.[2] // "") != "" then {pattern: .[2]} else {} end))' "$W/excluded.tsv")" \
    --argjson denied "$codex_denied" \
    '{base: $base, head: $head, baseRef: $baseRef, headRef: $headRef, include: $include, exclude: $exclude, context: $context,
      hardExclude: $hard, files: $files, extras: $extras, excluded: $excluded, codexDenied: $denied}' > "$D/manifest.json" ||
    { rollback; die "could not write $D/manifest.json"; }
  rm -rf "$W"
  jq -c --arg snap "$D/snap" --arg diff "$D/range.diff" --arg man "$D/manifest.json" \
    --argjson diffBytes "$(wc -c < "$D/range.diff" | tr -d ' ')" \
    '{step: "snapshot", ok: true, base, head, snap: $snap, diff: $diff, manifest: $man,
      files: (.files | length), bytes: ([.files[].bytes] | add // 0), diffBytes: $diffBytes,
      extras: (.extras | length), excluded: (.excluded | length), codexDenied}' "$D/manifest.json"
}

# ---------------------------------------------------------------------------
do_fingerprint() {
  [ -n "$REPO" ] || usage "fingerprint needs --repo --path"
  [ ${#PATHS[@]} -gt 0 ] || usage "fingerprint needs at least one --path"
  [ ${#POS[@]} -eq 0 ] || usage "unexpected argument ${POS[0]}"
  local g R head EMPTY W
  for g in "${PATHS[@]}"; do check_glob --path "$g"; done
  FP_OUT="$OUT"
  [ -z "$FP_OUT" ] || check_abs --out "$FP_OUT"
  R=$(repo_top "$REPO")
  W=$(mktemp -d "${TMPDIR:-/tmp}/review-fp.XXXXXX") || die "mktemp failed"
  # shellcheck disable=SC2064  # expand now: the dir is local to this call
  trap "rm -rf '$W'" EXIT
  pathspecs glob "${PATHS[@]}" > "$W/spec"
  local specs=() s
  while IFS= read -r s; do specs+=("$s"); done < "$W/spec"
  head=$(git -C "$R" --no-optional-locks rev-parse --verify --quiet HEAD) || head=""
  EMPTY=$(empty_tree "$R")

  # status: "XY path" per changed/untracked path under the paths, hard excludes out.
  local ent xy path
  git -C "$R" --no-optional-locks -c core.quotePath=false status --porcelain=v1 -uall -z --no-renames -- "${specs[@]}" > "$W/st.z" 2>"$W/err" ||
    die "could not read the status of $R: $(head -c 300 "$W/err")"
  : > "$W/st"
  while IFS= read -r -d '' ent; do
    xy="${ent:0:2}"; path="${ent:3}"
    case "$path" in *"$NL"*|*"$TAB"*) die "a path contains a newline or a tab — refusing" ;; esac
    printf '%s\t%s\n' "$xy" "$path" >> "$W/st"
  done < "$W/st.z"
  split_hard "$W/st" "$W/st.keep" "$W/st.drop"
  # tree: the content of each of those paths now.
  : > "$W/tree"
  while IFS="$TAB" read -r xy path; do
    if [ -L "$R/$path" ]; then printf 'link %s %s\n' "$(readlink "$R/$path")" "$path"
    elif [ -f "$R/$path" ]; then printf '%s %s\n' "$(git -C "$R" hash-object --no-filters -- "$path")" "$path"
    else printf 'absent %s\n' "$path"
    fi
  done < "$W/st.keep" > "$W/tree"
  # committed: HEAD's blobs under the paths.
  : > "$W/cm.keep"
  if [ -n "$head" ]; then
    list_raw "$R" "$EMPTY" "$head" "$W/cm" "$W/spec" || die "could not list HEAD's paths in $R"
    split_hard "$W/cm" "$W/cm.keep" "$W/cm.drop"
  fi
  local status tree committed json
  status=$(cut -f1,2 "$W/st.keep" | sed "s/$TAB/ /")
  tree=$(git -C "$R" hash-object --stdin < "$W/tree")
  committed=$(git -C "$R" hash-object --stdin < "$W/cm.keep")
  json=$(jq -n -c --arg head "$head" --arg status "$status" --arg tree "$tree" --arg committed "$committed" \
    --argjson paths "$(printf '%s\n' "${PATHS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    '{step: "fingerprint", head: $head, paths: $paths, status: $status, tree: $tree, committed: $committed}') || die "could not build the fingerprint"
  if [ -n "$FP_OUT" ]; then
    mkdir -p "$(dirname "$FP_OUT")" && printf '%s\n' "$json" > "$FP_OUT" || die "could not write $FP_OUT"
  fi
  printf '%s\n' "$json"
}

# ---------------------------------------------------------------------------
do_compare() {
  [ ${#POS[@]} -eq 2 ] || usage "compare needs exactly two fingerprint files: compare A.json B.json"
  local a="${POS[0]}" b="${POS[1]}" f
  for f in "$a" "$b"; do
    [ -f "$f" ] || usage "not a file: $f"
    jq -e 'type == "object" and .step == "fingerprint" and (.status | type) == "string" and (.tree | type) == "string" and (.committed | type) == "string"' "$f" >/dev/null 2>&1 ||
      usage "not a review-stage fingerprint: $f"
  done
  local out
  out=$(jq -n -c --slurpfile a "$a" --slurpfile b "$b" '
    $a[0] as $x | $b[0] as $y
    | [ (if $x.committed != $y.committed then "committed" else empty end),
        (if $x.status != $y.status then "status" else empty end),
        (if $x.tree != $y.tree then "tree" else empty end),
        (if $x.paths != $y.paths then "paths" else empty end) ] as $ch
    | {step: "compare", same: ($ch | length == 0), changed: $ch, headMoved: ($x.head != $y.head),
       detail: (if ($ch | length) == 0 then (if $x.head != $y.head then "SAME: HEAD moved, but nothing under the paths changed" else "SAME: nothing under the paths changed" end)
                else "SOURCE_CHANGED: " + ($ch | join(", ")) + " changed under the paths" end)}') || die "compare failed"
  printf '%s\n' "$out"
  [ "$(printf '%s' "$out" | jq -r .same)" = true ] && exit 0
  exit 7
}

case "$SUB" in
  snapshot)    do_snapshot ;;
  fingerprint) do_fingerprint ;;
  compare)     do_compare ;;
  *)           usage "review-stage.sh snapshot|fingerprint|compare [options] (see the header)" ;;
esac
