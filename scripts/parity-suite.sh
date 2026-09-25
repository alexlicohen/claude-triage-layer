#!/bin/bash
# scripts/parity-suite.sh — the task-suite side of a parity run
# (workflows/triage-parity.js). Loads and validates a suite of parity tasks,
# materializes one task into a throwaway git repo OUTSIDE its source, proves a
# task is well-formed (unsolved at base, solved by its reference fix), and
# scores a reviewer's findings against a seeded-defect key. The suite itself is
# private data kept outside this repo; nothing here knows any task's content.
#
# Usage:
#   parity-suite.sh list         --suite DIR
#   parity-suite.sh materialize  --task DIR --out DIR [--env-map FILE]
#   parity-suite.sh verify-task  --task DIR --out DIR [--env-map FILE]
#   parity-suite.sh fingerprint  --task DIR
#   parity-suite.sh score-review --key FILE --findings FILE
#
# Task format: <suite>/<band>/<id>/task.json (<band> is N or bN), fields in
# scripts/README.md. Paths inside task.json are relative to the task dir and
# may not leave it.
#
# NO REAL PATHS TO CANDIDATES: brief, acceptance and checks are shown to the
# candidates, so none may name a path under $HOME (/Users/, ~/, $HOME or the
# actual home dir — a task failing this is invalid, exit 2). A check names a
# tool only as "$PARITY_<NAME>" ([A-Z0-9_]+); the env map (--env-map FILE, else
# $PARITY_ENV_MAP, else ~/.agents/parity/envs.json: {"PARITY_<NAME>": "/abs"})
# supplies the path at grading, OUTSIDE any sandbox. patch-check.sh owns that
# rule (--print-env); an unmapped variable a check references is exit 2 naming
# it. source.repo is exempt: it is never shown to a candidate.
#
# list         prints a JSON array of every task (task.json + "taskDir":
#              absolute path), sorted by band then id. Any invalid task => exit 2
#              naming it; nothing is printed on stdout then.
# materialize  creates <out>/repo from the task source, holding EXACTLY ONE
#              commit and no source history (no clone, no source refs, no
#              unreachable source objects — a reviewer must never be able to
#              `git log`/`git show` its way to a seeded defect or a fix):
#                git       `git init` a fresh repo, then extract the base tree
#                          with `git archive <base> | tar -x` (no history);
#                generator `<taskDir>/<script> <out>/repo` must leave a git repo
#                          with >= 1 commit and a clean tree (its own history is
#                          discarded below, same as the git source).
#              setup.patch (if any) is applied to the working tree, then the
#              whole tree (+setup) is committed as ONE orphan root commit with a
#              fixed identity and date (sha deterministic), HEAD left detached;
#              every branch/tag/remote-tracking ref is then deleted, the reflog
#              expired and `git gc --prune=now` run, so no source or generator
#              commit is reachable, tagged or branched. Never writes into
#              the source repo. Refuses (exit 3) a source/task path with a
#              clip-creator component. DENY PROPAGATION: the materialized repo's
#              git-common-dir is itself, so ext-run.sh would no longer see the
#              source's .codex-deny markers (or its CODEX_DENY_REPOS names); any
#              such status found walking up from the source to $HOME is written as
#              <out>/.codex-deny, which ext-run finds walking up from the
#              materialized repo (and from worktrees of it). (agy was retired
#              2026-09-24: its .agy-deny markers are no longer propagated.)
#              Prints {"repo","sha","denied":{"codex":bool}} — denied is what
#              ext-run will see from <out>/repo. An <out> this command
#              made before (it holds .parity-materialized) is rebuilt; any other
#              non-empty <out> is refused. A build task's checks must resolve
#              against the env map (unmapped PARITY_ variable => exit 2, nothing
#              made). SELF-CHECK ENV: only a task with "selfCheckEnv": true gets
#              <out>/repo/.parity-env (the `export PARITY_X=...` lines, so a
#              candidate can run `. .parity-env` and then the checks) — the
#              trade-off: it reveals tool paths, never repo content. .parity-env
#              is listed in the repo's .git/info/exclude (shared by every
#              worktree of it), so it never enters a candidate's diff.
# verify-task  materializes into --out, then:
#                build   patch-check.sh runs the checks (the env map's PARITY_
#                        variables exported) at base + overlay (an empty
#                        patch) and with solution.patch + overlay; prints
#                        {"id","kind","sha","baseFails","solutionPasses","ok"}.
#                review  key.json is a non-empty seed list whose files exist at
#                        the materialized sha; prints {"id","kind","sha","seeds","missing","ok"}.
#              exit 0 when ok, 1 when not.
# fingerprint  SOURCE-REPO LEAK GUARD (triage-parity runs it before a task's
#              candidates and after grading). A git source prints
#              {"id","source":"git","guarded":true,"name":<repo dir name>,
#               "head":<HEAD sha>, "tree":<hash of `status --porcelain=v1 -uall`
#               + the content of every modified/untracked non-ignored file>,
#               "ignored":<hash of the IGNORED files: their count + size/mtime of
#               the first PARITY_FP_IGNORED_CAP (5000), shallowest first>,
#               "refs":<hash of refs/heads, refs/tags, refs/stash, the repo
#               config and non-sample hooks>}; a generator source prints
#              {"id","source":"generator","guarded":false} (no source repo: the
#              task is UNGUARDED, and says so). Read-only
#              (--no-optional-locks: not even the index is refreshed). A missing
#              or non-git source.repo => exit 1; clip-creator => exit 3.
# score-review deterministic: key = [{file,line,id,desc}] (or {"seeds":[...]}),
#              findings = [{file,line,desc}] (or {"findings":[...]}). A finding
#              matches a seed when the file is the same (a finding path ending in
#              /<seed file> also counts) and |line diff| <= 3; pairs are assigned
#              closest-first (ties: finding order, then seed order) and each seed
#              and each finding is used at most once. Prints
#              {"recall","precision","matched":[seed ids in key order],"seeds","findings"}.
#              No findings => precision 0.
#
# Exit codes: 0 ok; 1 the step failed (JSON or stderr says why); 2 usage error or
#             invalid task, nothing done; 3 REFUSED (deny-listed source).
set -uo pipefail
export LC_ALL=C
# Inherited git redirection (GIT_DIR & co. from a hook or a caller) would point
# every `git -C` below — the source lookup included — at another repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Mirrors HARD_DENY_REPOS in ext-run.sh (the owner of deny decisions);
# test/parity-suite.sh fails if the two ever differ.
HARD_DENY_REPOS="clip-creator"
VENDORS="codex"
MATERIALIZED_MARK=".parity-materialized"

die() { echo "parity-suite: $1" >&2; exit "${2:-1}"; }
usage() { die "USAGE: $1" 2; }
command -v jq >/dev/null 2>&1 || usage "jq is required"
command -v git >/dev/null 2>&1 || usage "git is required"

SUB="${1:-}"
[ $# -gt 0 ] && shift
SUITE="" TASK="" OUT="" KEY="" FINDINGS="" ENV_MAP=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage "$1 needs a value"
  case "$1" in
    --suite)    SUITE="$2" ;;
    --env-map)  ENV_MAP="$2" ;;
    --task)     TASK="$2" ;;
    --out)      OUT="$2" ;;
    --key)      KEY="$2" ;;
    --findings) FINDINGS="$2" ;;
    *)          usage "unknown argument $1" ;;
  esac
  shift 2
done

# phys PATH — physical form of an absolute path that may not exist yet.
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

# ---------------------------------------------------------------------------
# Task validation — SINGLE OWNER of the task format. validate_task DIR prints
# the task JSON merged with the absolute taskDir, or the problems on stderr
# (return 1).
# ---------------------------------------------------------------------------
JQ_VALIDATE='
def str: type == "string" and length > 0;
def rel: str and (startswith("/") | not) and ((split("/") | index("..")) == null);
def opt(f; msg): if has(f) and .[f] != null then (if (.[f] | rel) then empty else msg end) else empty end;
# A real path under $HOME in candidate-visible text (brief, acceptance, checks).
def underhome: . as $s | type == "string" and (contains("/Users/") or contains("~/") or test("\\$\\{?HOME([^A-Za-z0-9_]|$)")
  or ([$home, $homeRaw] | map(select(length > 1)) | any(. as $h | $s | contains($h + "/"))));
if type != "object" then ["task.json is not a JSON object"] else [
  (if (.id | str) and (.id | test("^[A-Za-z0-9._-]+$")) then empty else "id must be a non-empty file-name-safe string" end),
  (if (.band | type) == "number" and (.band as $b | [1,2,3,4] | index($b)) != null then empty else "band must be 1, 2, 3 or 4" end),
  (if .kind == "build" or .kind == "review" then empty else "kind must be build or review" end),
  (if (.source | type) != "object" then "source must be an object"
   elif .source.type == "git" then
     (if (.source.repo | str) and (.source.repo | startswith("/")) then empty else "source.repo must be an absolute path" end),
     (if (.source.base | str) then empty else "source.base must be a non-empty revision" end)
   elif .source.type == "generator" then
     (if (.source.script | rel) then empty else "source.script must be a relative path inside the task dir" end)
   else "source.type must be git or generator" end),
  opt("setup"; "setup must be a relative path inside the task dir"),
  opt("overlay"; "overlay must be a relative path inside the task dir"),
  opt("solution"; "solution must be a relative path inside the task dir"),
  opt("key"; "key must be a relative path inside the task dir"),
  (if (.brief | str) then empty else "brief must be a non-empty string" end),
  (if (.acceptance | str) then empty else "acceptance must be a non-empty string" end),
  (if (.files | type) == "array" and (.files | length) > 0 and all(.files[]; str) then empty else "files must be a non-empty array of paths" end),
  (if .kind == "build" then
     (if (.checks | type) == "array" and (.checks | length) > 0 and all(.checks[]; str) then empty else "checks must be a non-empty array of shell commands (build task)" end)
   elif has("checks") and .checks != null then
     (if (.checks | type) == "array" and all(.checks[]; str) then empty else "checks must be an array of shell commands" end)
   else empty end),
  (if .grading == "check" or .grading == "rubric" or .grading == "seeded" then empty else "grading must be check, rubric or seeded" end),
  (if .kind == "review" and .grading != "seeded" then "a review task is graded seeded" else empty end),
  (if .grading == "seeded" and .kind != "review" then "grading seeded is for review tasks" else empty end),
  (if (.grading == "rubric" or .grading == "seeded") and ((.key | rel) | not) then "grading \(.grading) needs a key" else empty end),
  (if .grading == "seeded" and ((.key // "") | endswith(".json") | not) then "a seeded key must be a .json file" else empty end),
  (if (.vendors | type) == "array" and (.vendors | length) > 0 and all(.vendors[]; . == "claude" or . == "codex" or . == "agy") then empty else "vendors must be a non-empty subset of claude, codex (agy: retired 2026-09-24, still tolerated in older task files)" end),
  (if has("timeoutMin") and .timeoutMin != null then (if (.timeoutMin | type) == "number" and .timeoutMin > 0 then empty else "timeoutMin must be a positive number" end) else empty end),
  (if has("selfCheckEnv") and .selfCheckEnv != null then (if (.selfCheckEnv | type) == "boolean" then empty else "selfCheckEnv must be true or false" end) else empty end),
  ([{f: "brief", v: .brief}, {f: "acceptance", v: .acceptance}]
   + (if (.checks | type) == "array" then [.checks | to_entries[] | {f: "checks[\(.key)]", v: .value}] else [] end)
   | .[] | select(.v | underhome)
   | "\(.f) names a path under $HOME (candidates see it): name a tool as \"$PARITY_<NAME>\" from the env map instead (scripts/README.md)")
] end'

validate_task() { # $1 task dir -> merged JSON on stdout, or problems on stderr + return 1
  local dir="$1" tj errs bandDir band id rel
  [ -d "$dir" ] || { echo "task dir not found: $dir" >&2; return 1; }
  dir=$(cd "$dir" && pwd -P)
  tj="$dir/task.json"
  [ -f "$tj" ] || { echo "$dir: no task.json" >&2; return 1; }
  jq -e . "$tj" >/dev/null 2>&1 || { echo "$tj: not valid JSON" >&2; return 1; }
  errs=$(jq -r --arg home "$HOME_P" --arg homeRaw "${HOME:-}" "$JQ_VALIDATE | .[]" "$tj" 2>&1)
  if [ -n "$errs" ]; then printf '%s\n' "$errs" | sed "s#^#$tj: #" >&2; return 1; fi
  id=$(jq -r .id "$tj"); band=$(jq -r .band "$tj")
  [ "$id" = "$(basename "$dir")" ] || { echo "$tj: id \"$id\" must equal its directory name $(basename "$dir")" >&2; return 1; }
  bandDir=$(basename "$(dirname "$dir")")
  case "$bandDir" in "$band"|"b$band"|"B$band") ;; *) echo "$tj: band $band does not match its band directory $bandDir" >&2; return 1 ;; esac
  for rel in $(jq -r '[.setup, .solution, .key] | map(select(. != null)) | .[]' "$tj"); do
    [ -f "$dir/$rel" ] || { echo "$tj: $rel is not a file in the task dir" >&2; return 1; }
  done
  rel=$(jq -r '.overlay // empty' "$tj")
  if [ -n "$rel" ] && [ ! -d "$dir/$rel" ]; then echo "$tj: overlay $rel is not a directory in the task dir" >&2; return 1; fi
  rel=$(jq -r 'if .source.type == "generator" then .source.script else empty end' "$tj")
  if [ -n "$rel" ] && [ ! -x "$dir/$rel" ]; then echo "$tj: generator $rel is not an executable file in the task dir" >&2; return 1; fi
  jq -c --arg d "$dir" '. + {taskDir: $d}' "$tj"
}

# ---------------------------------------------------------------------------
do_list() {
  [ -n "$SUITE" ] || usage "list needs --suite"
  [ -d "$SUITE" ] || usage "--suite is not a directory: $SUITE"
  local s tj all="" one bad=0 dups
  s=$(cd "$SUITE" && pwd -P)
  while IFS= read -r tj; do
    [ -n "$tj" ] || continue
    if one=$(validate_task "$(dirname "$tj")"); then all="$all$one
"
    else bad=1
    fi
  done < <(find "$s" -mindepth 3 -maxdepth 3 -name task.json | sort)
  [ "$bad" -eq 0 ] || die "invalid task(s) in $s — see above" 2
  dups=$(printf '%s' "$all" | jq -rs 'group_by(.id) | map(select(length > 1) | .[0].id) | .[]')
  [ -z "$dups" ] || die "duplicate task id(s) in $s: $dups" 2
  printf '%s' "$all" | jq -cs 'sort_by(.band, .id)'
}

# ---------------------------------------------------------------------------
# Deny propagation.
# has_hard_deny PATH — PATH has a hard-denied component.
has_hard_deny() {
  local name
  for name in $HARD_DENY_REPOS; do
    case "/$1/" in */"$name"/*) return 0 ;; esac
  done
  return 1
}
# deny_names VENDOR — the extra names ext-run denies for VENDOR.
deny_names() { case "$1" in codex) echo "${CODEX_DENY_REPOS:-}" ;; esac; }
# denied_at VENDOR PATH — prints the reason ext-run would refuse VENDOR on PATH
# (a .VENDOR-deny marker from PATH up to AND INCLUDING $HOME, or / outside it —
# the same walk as ext-run.sh — or a deny-listed name component); prints nothing
# otherwise.
denied_at() {
  local v="$1" p="$2" d name
  for name in $(deny_names "$v"); do
    case "/$p/" in */"$name"/*) echo "$v deny-listed name '$name' in $p"; return 0 ;; esac
  done
  d="$p"
  while [ -n "$d" ]; do
    if [ -f "$d/.$v-deny" ]; then echo "$d/.$v-deny"; return 0; fi
    case "$d" in /|"${HOME:-/}"|"$HOME_P") break ;; esac
    [ "$(dirname "$d")" != "$d" ] || break   # a relative path bottoms out at "."
    d=$(dirname "$d")
  done
  return 0
}
# main_worktree_of PATH — the main worktree of the repository PATH is in.
main_worktree_of() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] && [ -d "$common" ] || return 0
  common=$(cd "$common" && pwd -P)
  case "$common" in */.git) dirname "$common" ;; *) printf '%s\n' "$common" ;; esac
}

# task_env TASK_JSON — the `export PARITY_X=...` lines for the variables the
# task's checks reference (empty when none), via patch-check.sh --print-env, the
# ONE owner of the env-map rule. Non-zero (its stderr names why) when a
# referenced variable is unmapped or the map is missing/invalid.
task_env() {
  local checks
  checks=$(printf '%s' "$1" | jq -r '(.checks // []) | join(" && ")')
  [ -n "$checks" ] || return 0
  if [ -n "$ENV_MAP" ]; then
    "$SCRIPT_DIR/patch-check.sh" --print-env --env-map "$ENV_MAP" --check "$checks"
  else
    "$SCRIPT_DIR/patch-check.sh" --print-env --check "$checks"
  fi
}

# ---------------------------------------------------------------------------
# materialize_task TASKDIR OUT — SINGLE OWNER of turning a task into a repo.
# Sets TASK_JSON, MAT_REPO, MAT_SHA, DENIED_CODEX. Exits on error.
materialize_task() {
  local tdir="$1" out="$2" type src base script setup srcTop srcMain p v why made_repo=0 wrote excl
  case "$out" in /*) ;; *) usage "--out must be an absolute path (got '$out')" ;; esac
  case "/$out/" in */../*|*/./*) usage "--out must not contain . or .. components" ;; esac
  TASK_JSON=$(validate_task "$tdir") || die "invalid task: $tdir" 2
  tdir=$(printf '%s' "$TASK_JSON" | jq -r .taskDir)
  out=$(phys "$out") || usage "could not resolve --out"
  within "$out" "$tdir" && usage "refusing: --out $out is inside the task dir $tdir"
  within "$tdir" "$out" && usage "refusing: --out $out contains the task dir $tdir"
  type=$(printf '%s' "$TASK_JSON" | jq -r .source.type)

  # Identity, dates and config fixed for every commit this makes (and for a
  # generator's): the same task always yields the same sha. (GIT_DIR & co. were
  # unset at the top.)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=parity GIT_AUTHOR_EMAIL=parity@localhost GIT_COMMITTER_NAME=parity GIT_COMMITTER_EMAIL=parity@localhost
  export GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000" GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000"

  # The paths whose deny status the clone must inherit — an ARRAY, so a path with
  # spaces stays one path (a word-split path would lose its marker).
  DENY_SOURCES=("$tdir")
  if [ "$type" = git ]; then
    src=$(printf '%s' "$TASK_JSON" | jq -r .source.repo)
    base=$(printf '%s' "$TASK_JSON" | jq -r .source.base)
    has_hard_deny "$src" && die "REFUSED: source $src is under a hard-denied repo ($HARD_DENY_REPOS)" 3
    [ -d "$src" ] || die "source.repo is not a directory: $src" 2
    srcTop=$(git -C "$src" rev-parse --show-toplevel 2>/dev/null) || die "source.repo is not a git work tree: $src" 2
    srcTop=$(cd "$srcTop" && pwd -P)
    srcMain=$(main_worktree_of "$srcTop")
    DENY_SOURCES+=("$srcTop")
    [ -n "$srcMain" ] && DENY_SOURCES+=("$srcMain")
    within "$out" "$srcTop" && usage "refusing: --out $out is inside the source repo $srcTop"
    [ -n "$srcMain" ] && within "$out" "$srcMain" && usage "refusing: --out $out is inside the source repo $srcMain"
  fi
  for p in "${DENY_SOURCES[@]}"; do
    has_hard_deny "$p" && die "REFUSED: $p is under a hard-denied repo ($HARD_DENY_REPOS)" 3
  done
  # The checks' PARITY_ tool variables must all resolve BEFORE anything is made
  # (patch-check.sh owns the rule; its stderr names an unmapped variable).
  ENV_EXPORTS=$(task_env "$TASK_JSON") || die "the task's checks do not resolve against the env map (see above): $tdir" 2

  if [ -d "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    [ -f "$out/$MATERIALIZED_MARK" ] || usage "refusing: --out $out is not empty and was not made by materialize"
    rm -rf "${out:?}/repo" "${out:?}/$MATERIALIZED_MARK"
    for v in $VENDORS; do rm -f "$out/.$v-deny"; done
  fi
  mkdir -p "$out" || die "could not create $out"
  MAT_REPO="$out/repo"

  rollback() { [ "$made_repo" -eq 1 ] && rm -rf "$MAT_REPO"; for v in $VENDORS; do rm -f "$out/.$v-deny"; done; }
  fail() { rollback; die "$1" "${2:-1}"; }

  made_repo=1
  if [ "$type" = git ]; then
    MAT_SHA=$(git -C "$srcTop" --no-optional-locks rev-parse --verify --quiet "$base^{commit}") || fail "source.base does not name a commit in $srcTop: $base" 2
    mkdir -p "$MAT_REPO" || fail "could not create $MAT_REPO"
    git -C "$MAT_REPO" init -q >&2 || fail "git init failed"
    # No clone, no source refs: only the ONE tree at $MAT_SHA ever reaches the
    # materialized repo — no history, so a reviewer there can never git-log or
    # git-show its way to a seeded defect or the fix (the ANSWER LEAK).
    git -C "$srcTop" --no-optional-locks archive "$MAT_SHA" | tar -x -C "$MAT_REPO" -f - || fail "could not extract $MAT_SHA into $MAT_REPO"
  else
    script=$(printf '%s' "$TASK_JSON" | jq -r .source.script)
    ( cd "$out" && "$tdir/$script" "$MAT_REPO" ) >&2 < /dev/null || fail "generator $script failed"
    [ -d "$MAT_REPO" ] || fail "generator $script did not create $MAT_REPO"
    [ "$(cd "$MAT_REPO" && pwd -P)" = "$(git -C "$MAT_REPO" rev-parse --show-toplevel 2>/dev/null)" ] || fail "generator $script did not leave a git repo at $MAT_REPO"
    git -C "$MAT_REPO" rev-parse --verify --quiet HEAD >/dev/null || fail "generator $script left a repo with no commit"
  fi

  setup=$(printf '%s' "$TASK_JSON" | jq -r '.setup // empty')
  if [ -n "$setup" ]; then
    git -C "$MAT_REPO" apply --binary "$tdir/$setup" >&2 || fail "setup patch $setup does not apply"
  fi

  # Reduce to ONE orphan root commit holding the tree (+ setup), whatever git
  # history the source or a generator brought with it — the materialized repo
  # never carries source history, refs or unreachable source objects. Fixed
  # identity/dates (exported above) keep the sha deterministic.
  git -C "$MAT_REPO" add -A >&2 || fail "git add failed"
  ROOT_TREE=$(git -C "$MAT_REPO" write-tree) || fail "write-tree failed"
  ROOT_SHA=$(git -C "$MAT_REPO" commit-tree "$ROOT_TREE" -m "parity materialize: $(printf '%s' "$TASK_JSON" | jq -r .id)") || fail "commit-tree failed"
  git -C "$MAT_REPO" -c core.hooksPath=/dev/null checkout -q --detach "$ROOT_SHA" >&2 || fail "could not detach HEAD at $ROOT_SHA"
  for r in $(git -C "$MAT_REPO" for-each-ref --format='%(refname)' refs/heads refs/tags refs/remotes); do
    git -C "$MAT_REPO" update-ref -d "$r" >&2 || fail "could not delete ref $r"
  done
  git -C "$MAT_REPO" reflog expire --expire=now --all >&2 || fail "reflog expire failed"
  git -C "$MAT_REPO" -c gc.reflogExpire=now -c gc.reflogExpireUnreachable=now gc --prune=now -q >&2 || fail "gc failed"
  # Self-check env (opt-in): excluded FIRST, so the clean-tree check below also
  # proves it can never show up in a status or a diff of this repo or its worktrees.
  if [ "$(printf '%s' "$TASK_JSON" | jq -r '.selfCheckEnv == true')" = true ]; then
    excl=$(git -C "$MAT_REPO" rev-parse --path-format=absolute --git-path info/exclude) || fail "could not locate info/exclude in $MAT_REPO"
    mkdir -p "$(dirname "$excl")" && printf '/.parity-env\n' >> "$excl" || fail "could not write $excl"
    { printf '# parity-suite.sh materialize (selfCheckEnv): the tool paths the checks use. Run: . .parity-env\n'
      [ -z "$ENV_EXPORTS" ] || printf '%s\n' "$ENV_EXPORTS"; } > "$MAT_REPO/.parity-env" || fail "could not write $MAT_REPO/.parity-env"
  fi
  [ -z "$(git -C "$MAT_REPO" status --porcelain 2>/dev/null)" ] || fail "materialized tree is not clean (generator or setup left uncommitted files)"
  MAT_SHA=$(git -C "$MAT_REPO" rev-parse HEAD) || fail "no HEAD in $MAT_REPO"

  # Propagate: any deny status of the source becomes a marker next to the clone.
  for v in $VENDORS; do
    wrote=0
    for p in "${DENY_SOURCES[@]}"; do
      why=$(denied_at "$v" "$p")
      if [ -n "$why" ] && [ "$wrote" -eq 0 ]; then
        printf 'propagated by parity-suite.sh materialize: %s\n' "$why" > "$out/.$v-deny" || fail "could not write $out/.$v-deny"
        wrote=1
      fi
    done
  done
  DENIED_CODEX=false
  [ -n "$(denied_at codex "$MAT_REPO")" ] && DENIED_CODEX=true
  printf '%s\n' "$MAT_SHA" > "$out/$MATERIALIZED_MARK"
}

do_materialize() {
  [ -n "$TASK" ] && [ -n "$OUT" ] || usage "materialize needs --task --out"
  materialize_task "$TASK" "$OUT"
  jq -nc --arg repo "$MAT_REPO" --arg sha "$MAT_SHA" --argjson c "$DENIED_CODEX" \
    '{repo: $repo, sha: $sha, denied: {codex: $c}}'
}

# ---------------------------------------------------------------------------
do_verify() {
  [ -n "$TASK" ] && [ -n "$OUT" ] || usage "verify-task needs --task --out"
  materialize_task "$TASK" "$OUT"
  local tdir id kind out sol overlay tmin checks lines l1 l2 baseFails solPasses ok seeds missing f keyf
  tdir=$(printf '%s' "$TASK_JSON" | jq -r .taskDir)
  id=$(printf '%s' "$TASK_JSON" | jq -r .id)
  kind=$(printf '%s' "$TASK_JSON" | jq -r .kind)
  out=$(dirname "$MAT_REPO")
  if [ "$kind" = review ]; then
    keyf="$tdir/$(printf '%s' "$TASK_JSON" | jq -r .key)"
    if ! jq -e 'if type == "object" then .seeds else . end | type == "array" and length > 0 and
      all(.[]; (.file | type) == "string" and (.line | type) == "number" and (.id | type) == "string")' "$keyf" >/dev/null 2>&1; then
      jq -nc --arg id "$id" --arg sha "$MAT_SHA" '{id: $id, kind: "review", sha: $sha, seeds: 0, missing: [], ok: false, error: "key is not a non-empty [{file,line,id,desc}] seed list"}'
      exit 1
    fi
    seeds=$(jq 'if type == "object" then .seeds else . end | length' "$keyf")
    missing=""
    while IFS= read -r f; do
      git -C "$MAT_REPO" cat-file -e "$MAT_SHA:$f" 2>/dev/null || missing="$missing$f
"
    done < <(jq -r 'if type == "object" then .seeds else . end | .[].file' "$keyf" | sort -u)
    ok=true; [ -n "$missing" ] && ok=false
    printf '%s' "$missing" | jq -Rsc --arg id "$id" --arg sha "$MAT_SHA" --argjson n "$seeds" --argjson ok "$ok" \
      '{id: $id, kind: "review", sha: $sha, seeds: $n, missing: (split("\n") | map(select(length > 0))), ok: $ok}'
    [ "$ok" = true ] && exit 0
    exit 1
  fi

  sol=$(printf '%s' "$TASK_JSON" | jq -r '.solution // empty')
  if [ -z "$sol" ]; then
    jq -nc --arg id "$id" --arg sha "$MAT_SHA" '{id: $id, kind: "build", sha: $sha, baseFails: null, solutionPasses: null, ok: false, error: "no solution.patch: the task cannot be proven solvable"}'
    exit 1
  fi
  overlay=$(printf '%s' "$TASK_JSON" | jq -r '.overlay // empty')
  tmin=$(printf '%s' "$TASK_JSON" | jq -r '.timeoutMin // 10 | . * 60 | ceil')
  checks=$(printf '%s' "$TASK_JSON" | jq -r '.checks | join(" && ")')
  : > "$out/base.patch"
  set -- --repo "$MAT_REPO" --base "$MAT_SHA" --check "$checks" --timeout "$tmin"
  [ -n "$overlay" ] && set -- "$@" --overlay "$tdir/$overlay"
  [ -n "$ENV_MAP" ] && set -- "$@" --env-map "$ENV_MAP"
  lines=$("$SCRIPT_DIR/patch-check.sh" "$@" "$out/base.patch" "$tdir/$sol") || die "patch-check.sh failed: $lines"
  rm -f "$out/base.patch"
  l1=$(printf '%s\n' "$lines" | sed -n 1p); l2=$(printf '%s\n' "$lines" | sed -n 2p)
  # A patch-check error (e.g. overlay-failed: the hidden tests never ran) is no
  # grade at all — neither "base fails" nor "solution passes".
  baseFails=$(printf '%s' "$l1" | jq '.applies == true and .rc != null and .rc != 0 and (.error // null) == null')
  solPasses=$(printf '%s' "$l2" | jq '.applies == true and .rc == 0 and (.error // null) == null')
  ok=false; [ "$baseFails" = true ] && [ "$solPasses" = true ] && ok=true
  jq -nc --arg id "$id" --arg sha "$MAT_SHA" --argjson b "$baseFails" --argjson s "$solPasses" --argjson ok "$ok" \
    --argjson l1 "$l1" --argjson l2 "$l2" \
    '{id: $id, kind: "build", sha: $sha, baseFails: $b, solutionPasses: $s, ok: $ok}
     + (if $ok then {} else {baseTail: $l1.tail, solutionTail: $l2.tail} end)
     + (if ($l1.error // $l2.error) != null then {error: ($l1.error // $l2.error)} else {} end)'
  [ "$ok" = true ] && exit 0
  exit 1
}

# ---------------------------------------------------------------------------
# fingerprint — SINGLE OWNER of the source-repo leak-guard fingerprint.
# source_tree TOP — one hash over TOP's porcelain status and the content of every
# modified or untracked non-ignored file (so a second edit to an already-dirty
# file changes it too). Read-only: --no-optional-locks everywhere.
source_tree() {
  local top="$1" st
  st=$(git -C "$top" --no-optional-locks status --porcelain=v1 -uall) || return 1
  { printf '%s\n' "$st"
    git -C "$top" --no-optional-locks ls-files -z -m -o --exclude-standard | while IFS= read -r -d '' p; do
      if [ -L "$top/$p" ]; then printf 'link %s %s\n' "$(readlink "$top/$p")" "$p"
      elif [ -f "$top/$p" ]; then printf '%s %s\n' "$(git -C "$top" hash-object --no-filters -- "$p")" "$p"
      fi
    done
  } | git -C "$top" hash-object --stdin
}
# stat_lines — "<size> <mtime> <path>" per NUL-separated path on stdin (relative
# to the cwd): BSD stat on macOS, GNU stat elsewhere; mtime with sub-second
# precision where the platform gives it.
stat_lines() {
  if stat --version >/dev/null 2>&1; then xargs -0 stat -c '%s %y %n' 2>/dev/null
  else xargs -0 stat -f '%z %Fm %N' 2>/dev/null
  fi
}
# ignored_tree TOP — one hash over TOP's IGNORED files (the cache-refresh class: a
# candidate or a grader regenerating a gitignored cache in the real repo): their
# count, plus size + mtime (not content: a venv is large) of the first
# PARITY_FP_IGNORED_CAP (default 5000) in shallow-first order, so small top-level
# caches are always covered and a huge deep tree (.venv, node_modules) only
# shifts the count. .DS_Store (Finder) is left out.
ignored_tree() {
  local top="$1" cap="${PARITY_FP_IGNORED_CAP:-5000}" list
  case "$cap" in ''|*[!0-9]*) die "PARITY_FP_IGNORED_CAP must be a whole number" 2 ;; esac
  list=$(git -C "$top" --no-optional-locks ls-files -o -i --exclude-standard) || return 1
  list=$(printf '%s\n' "$list" | grep -v -E -e '^$' -e '(^|/)\.DS_Store$' | awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1n -k2 | cut -f2-)
  { printf 'ignored %s\n' "$(printf '%s\n' "$list" | grep -c .)"
    [ -z "$list" ] || ( cd "$top" && printf '%s\n' "$list" | head -n "$cap" | tr '\n' '\0' | stat_lines )
  } | git -C "$top" hash-object --stdin
}
# refs_tree TOP — one hash over TOP's local refs (branches, tags, the stash), its
# repo config and its hooks (every non-.sample file): what a stray git command
# can change without touching HEAD or the work tree. Remote-tracking refs are
# left out (a background fetch is not the candidate's doing).
refs_tree() {
  local top="$1" cfg hooks
  cfg=$(cd "$top" && git rev-parse --git-path config 2>/dev/null) || cfg=""
  hooks=$(cd "$top" && git rev-parse --git-path hooks 2>/dev/null) || hooks=""
  case "$cfg" in ""|/*) ;; *) cfg="$top/$cfg" ;; esac
  case "$hooks" in ""|/*) ;; *) hooks="$top/$hooks" ;; esac
  { git -C "$top" --no-optional-locks for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags refs/stash || return 1
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then printf 'config %s\n' "$(git hash-object --no-filters -- "$cfg")"; fi
    if [ -n "$hooks" ] && [ -d "$hooks" ]; then
      for h in "$hooks"/*; do
        [ -f "$h" ] || continue
        case "$h" in *.sample) continue ;; esac
        printf 'hook %s %s\n' "$(git hash-object --no-filters -- "$h")" "$(basename "$h")"
      done
    fi
  } | git -C "$top" hash-object --stdin
}
do_fingerprint() {
  [ -n "$TASK" ] || usage "fingerprint needs --task"
  local tj id src top head tree ign refs
  tj=$(validate_task "$TASK") || die "invalid task: $TASK" 2
  id=$(printf '%s' "$tj" | jq -r .id)
  if [ "$(printf '%s' "$tj" | jq -r .source.type)" != git ]; then
    # Nothing to guard: say so, so a report can mark the task unguarded.
    jq -nc --arg id "$id" '{id: $id, source: "generator", guarded: false}'
    return 0
  fi
  src=$(printf '%s' "$tj" | jq -r .source.repo)
  has_hard_deny "$src" && die "REFUSED: source $src is under a hard-denied repo ($HARD_DENY_REPOS)" 3
  [ -d "$src" ] || die "source.repo is not a directory: $src"
  top=$(git -C "$src" rev-parse --show-toplevel 2>/dev/null) || die "source.repo is not a git work tree: $src"
  top=$(cd "$top" && pwd -P)
  has_hard_deny "$top" && die "REFUSED: source $top is under a hard-denied repo ($HARD_DENY_REPOS)" 3
  head=$(git -C "$top" --no-optional-locks rev-parse --verify --quiet HEAD) || head=""
  tree=$(source_tree "$top") || die "could not read the status of $top"
  ign=$(ignored_tree "$top") || die "could not list the ignored files of $top"
  refs=$(refs_tree "$top") || die "could not read the refs of $top"
  [ -n "$tree" ] && [ -n "$ign" ] && [ -n "$refs" ] || die "could not fingerprint $top"
  jq -nc --arg id "$id" --arg name "$(basename "$top")" --arg head "$head" --arg tree "$tree" --arg ign "$ign" --arg refs "$refs" \
    '{id: $id, source: "git", guarded: true, name: $name, head: $head, tree: $tree, ignored: $ign, refs: $refs}'
}

# ---------------------------------------------------------------------------
# score-review — SINGLE OWNER of the seeded-review score.
do_score() {
  [ -n "$KEY" ] && [ -n "$FINDINGS" ] || usage "score-review needs --key --findings"
  [ -f "$KEY" ] || usage "--key not found: $KEY"
  [ -f "$FINDINGS" ] || usage "--findings not found: $FINDINGS"
  jq -e . "$KEY" >/dev/null 2>&1 || usage "--key is not valid JSON"
  jq -e . "$FINDINGS" >/dev/null 2>&1 || usage "--findings is not valid JSON"
  jq -nc --slurpfile k "$KEY" --slurpfile f "$FINDINGS" '
    def norm: tostring | sub("^(\\./)+"; "");
    def same($a; $b): ($a | norm) as $x | ($b | norm) as $y | $x == $y or ($x | endswith("/" + $y));
    def num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
    ($k[0] | if type == "object" then .seeds else . end) as $seeds
    | ($f[0] | if type == "object" then .findings else . end | if type == "array" then . else [] end) as $finds
    | [ range(0; $finds | length) as $i | range(0; $seeds | length) as $j
        | ($finds[$i].line | num) as $fl | ($seeds[$j].line | num) as $sl
        | select($fl != null and $sl != null and same($finds[$i].file; $seeds[$j].file))
        | (($fl - $sl) | fabs) as $d | select($d <= 3) | {i: $i, j: $j, d: $d} ]
    | sort_by(.d, .i, .j)
    | reduce .[] as $p ({fi: {}, sj: {}};
        if (.fi[$p.i | tostring] or .sj[$p.j | tostring]) then .
        else .fi[$p.i | tostring] = true | .sj[$p.j | tostring] = true end)
    | (.sj | keys | map(tonumber) | sort) as $m
    | { recall: (if ($seeds | length) == 0 then 0 else ($m | length) / ($seeds | length) end),
        precision: (if ($finds | length) == 0 then 0 else ($m | length) / ($finds | length) end),
        matched: [ $m[] | $seeds[.].id ],
        seeds: ($seeds | length), findings: ($finds | length) }'
}

case "$SUB" in
  list)         do_list ;;
  materialize)  do_materialize ;;
  verify-task)  do_verify ;;
  fingerprint)  do_fingerprint ;;
  score-review) do_score ;;
  *)            usage "parity-suite.sh <list|materialize|verify-task|fingerprint|score-review> [flags] (see the header)" ;;
esac
