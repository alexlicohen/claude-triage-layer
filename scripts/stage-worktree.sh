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
# worktree bookkeeping under .git/worktrees (each staged worktree's link manifest
# lives in its admin dir there), which `cleanup` removes again.
#
# Usage:
#   stage-worktree.sh create    --repo R --base REV --count N --dir D
#   stage-worktree.sh diff      --worktree W --base SHA --out FILE
#   stage-worktree.sh leakcheck --repo R --dir D [--line]
#   stage-worktree.sh cleanup   --repo R --dir D
#   stage-worktree.sh apply     --repo R --patch P [--require-clean]
#   stage-worktree.sh ignored   --repo R
#   stage-worktree.sh link      --repo R --base REV --worktree W
#   stage-worktree.sh link      --repo R --base REV --check
#
# create     resolves REV to a sha ONCE, records R's fingerprint (HEAD, `status
#            --porcelain=v1 -uall`, and a content manifest of every tracked +
#            untracked non-ignored path, plus the IGNORED paths as `ignored`
#            prints them — a candidate's accidental cache or build-output write is
#            a leak too) in D, then creates N detached worktrees
#            D/wt-1..D/wt-N at that sha (hooks off), and gives each one R's stage
#            links (`link`, below). D must be absolute, outside R, not containing R,
#            and absent or empty. Every per-repo opt-in is read at the SHA, never
#            at a moving HEAD: the leak exclusions of .triage-leakignore (see
#            `ignored`) are read ONCE here and kept in D/fingerprint.leakignore, so
#            leakcheck compares both snapshots under the same patterns even if HEAD
#            moves. Prints one JSON object:
#              {"sha","worktrees":["D/wt-1",...],"fingerprint":"D/fingerprint","head","repo",
#               "links":[P...],"linkRefused":[{"path","reason"}],
#               "leakignore":null|{"file","blob","patterns":[...],"excluded":N}}
#            (paths spelled as D was given). Any failure rolls back what it made —
#            an opt-in file that cannot be READ at the sha is a failure, never "no
#            opt-in"; a refused stage link is not (it is listed, and warned on stderr).
# diff       `git -C W add -A` then `git -C W diff --binary --cached SHA` into FILE
#            (new, deleted, binary and modified files; FILE is removed first, so a
#            stale patch never survives a failed diff). W must be a LINKED
#            worktree — a main working tree is refused, so this can never stage
#            into the real repo's index. Prints one JSON line:
#              {"step":"diff","worktree","patch","ok":true|false,"shortstat"|"error",
#               "ignoredNew":N,"gitlinks":[...]}
#            ignoredNew = files in W that .gitignore keeps OUT of the patch (a
#            candidate's new file there is not graded; .parity-env not counted);
#            gitlinks = nested repos the patch records only as a commit id. Stage
#            links are never in the patch nor in ignoredNew: exactly the paths in
#            W's link MANIFEST (`link` records every symlink it makes in
#            <W's git dir>/triage-stage-links) that are still symlinks — also when a
#            candidate's own `git add -A` already staged one (a `.venv/` pattern
#            does not ignore the symlink FILE .venv: it is unstaged again). Any
#            other symlink, a candidate's, stays in the patch. A manifest that
#            cannot be read, or a git step that fails, is ok:false.
# leakcheck  compares R now with the fingerprint in D. Prints one JSON line
#              {"step":"leakcheck","status":"CLEAN|LEAK|BASE_MOVED","leak","baseMoved",
#               "sha","headBefore","headAfter","paths":[...],"detail"}
#            LEAK = with HEAD unchanged, the status or any path's content changed;
#            with HEAD moved, any path's CONTENT changed (a commit alone only moves
#            status). BASE_MOVED = HEAD moved (someone committed) and nothing else
#            changed: grading stays at the recorded sha. --line prints the same
#            object plus "rc" as ONE line `LEAKCHECK {json}` — the single line a
#            relay copies verbatim (workflows/triage-compare.js parses it). Both
#            carry "leakignore": null when the stage has no exclusions, else
#            {"file":".triage-leakignore","blob","patterns":[...],"excluded":N}
#            (N = ignored paths the patterns left out of the comparison now).
# cleanup    `git worktree remove --force` each staged worktree, `git worktree
#            prune`, rm -rf D. Refuses a D with no fingerprint (not a stage dir).
#            An absent D is already clean (exit 0). Prints {"step":"cleanup","ok"}.
# apply      the ONE step here that writes the caller's tree, on purpose: applies a
#            chosen candidate's patch P to R (an inline bake-off's fallback). Only
#            an apply proven clean first is written, so exit 6 always means "R is
#            byte-identical":
#              1. `git apply --check` then `git apply` (index-free, so unstaged
#                 changes and untracked files elsewhere in R do not block it);
#              2. else `git apply --3way --check` — it exits 0 even when the merge
#                 WOULD conflict, so it counts as clean only with rc 0 AND no
#                 "conflict" in its output — then `git apply --3way`;
#              3. else nothing is written: exit 6.
#            --require-clean: first, every path P touches (`git apply --numstat`
#            for the paths it writes, plus the SOURCE of every rename or copy from
#            the patch headers) must be unmodified and not untracked in R, else
#            exit 6 and nothing is written — a patch never lands on top of the
#            caller's uncommitted work. Paths that cannot be listed, or a `git
#            status` that fails, are never clean: exit 6, treeModified false.
#            An empty P is a no-op success. Prints one JSON line
#              {"step":"apply","repo","patch","ok","applied","method":"plain|3way|empty|none",
#               "treeModified","error"?}
#            treeModified = the paths P touches (index entries and files) differ from
#            before this call: true after an apply, false on exit 6; after a FAILED
#            write it is measured (a failed 3-way can leave conflict markers), and
#            true when the paths could not be listed (unknown is never clean). A
#            caller must never run anything on the tree while it is true or absent.
#            The rule mirrors ext-run.sh apply_back() on purpose rather than being
#            shared: ext-run.sh stays self-contained (the single owner of every
#            external-CLI run, with its own exit-6 contract and diagnostics), and a
#            runtime dependency from that danger-zone script on this one was judged
#            worse than a three-command rule kept in two places — each copy has its
#            own conflict-marker mutation in qc/mutate.sh (51 there, 55 here).
# ignored    SINGLE OWNER of the real-repo leak fingerprint's IGNORED part — the
#            rule `create`/`leakcheck` here, `review-stage.sh fingerprint` and
#            `parity-suite.sh fingerprint` all use (they call this subcommand, never
#            a copy). Prints, sorted, one line per IGNORED untracked path of R:
#            "<path>\tign:<blob sha>" (content) for the first 2000 files of at most
#            256 KiB, "<path>\tign-meta:<size>:<mtime>" (nanosecond mtime where
#            Time::HiRes has it) for every other file, "\tlink:", "\tdir" or
#            "\tmissing" otherwise; paths are taken shallowest first and at most
#            100000 listed (STAGE_WT_IGN_LIST_MAX overrides; a test knob), then one
#            "\tign-count:<count>" line, so a change in the count still shows.
#            Left out — the ONE exclusion list, written by design while agents run
#            and not the tree: anything under .claude/, PROJECT_MEMORY*.md, and
#            Finder's .DS_Store at any depth. Read-only. Exit 0, 1 on a git failure
#            (a .triage-leakignore that cannot be read included).
#            PER-REPO EXCLUSIONS: a TRACKED .triage-leakignore at R's root holds
#            gitignore-style patterns (comments, `!`, `/`-anchoring, dir/ — and,
#            as in .gitignore, no re-including a file under an excluded dir: write
#            `data/*` + `!data/keep`). `ignored` reads it from HEAD, `create` from
#            the bake-off's sha (`git ls-tree` + `cat-file`), never from the working
#            tree, so an uncommitted edit cannot widen it; a non-regular-file entry
#            is ignored. Only IGNORED paths it
#            matches are left out (`git ls-files -o -i --exclude-from`): tracked and
#            untracked-not-ignored paths are never excludable (they are not in this
#            listing at all). Active, the output gains ONE line
#            "\tleakignore:<blob sha of the patterns>" (a change of the patterns
#            itself still shows) and stderr says how many paths were left out.
#            Absent or empty file = no exclusions, output byte-identical to before.
# link       SINGLE OWNER of the stage-link rule: symlinks each path listed in R's
#            TRACKED .triage-stage-links, read at REV (the bake-off's base sha —
#            every caller passes the same one, so the candidates' worktrees and every
#            grading worktree get the SAME grant however HEAD moves; one
#            repo-relative path per line, blank and #-lines skipped, a trailing /
#            dropped) into the LINKED worktree W of R, as W/P -> R/P — the opt-in
#            way to give a staged or grading worktree R's gitignored toolchain
#            (.venv, node_modules); `create` and patch-check.sh (every grading
#            worktree, right before its check runs) call it. Each link made is
#            appended to W's manifest (see `diff`). Refused (listed, not linked): an
#            absolute path, a . or .. component (a leading ./ too), a path tracked
#            in R, at REV or in W's index, a path that does not exist in R, is a
#            symlink there or resolves outside R, a path R does not gitignore, a
#            toolchain BOUND to R (see below), a path that already exists in W or
#            whose parent resolves outside W.
#            BOUND (links are ONLY for self-contained toolchains): a linked path
#            that refers back to R would run R's code, not W's, so checks would grade
#            the source repo — and no environment can undo that by precedence (an
#            import path that still reaches R imports a module the patch DELETED
#            from R's copy). Refused with a reason starting "imports the source
#            repo:", naming the file: inside R/P,
#              - a *.pth, *.egg-link, direct_url.json with "editable": true, or an
#                __editable__* file (setuptools' finder) that names R's absolute
#                path (physical or as git spells it, plain or %-encoded);
#              - a *.pth / *.egg-link path line, ABSOLUTE or RELATIVE (resolved
#                against the file's own directory, as site.py does; `import` and
#                # lines skipped), that resolves into R;
#              - a symlink whose target resolves into R (e.g. node_modules/local
#                -> ../packages/local, a workspace package);
#            where "into R" means R or below it but NOT inside R/P itself (a venv's
#            own lib64 -> lib is fine), resolved physically (symlinks followed, a
#            missing tail taken lexically). The scan is bounded: at most
#            STAGE_WT_BOUND_SCAN_MAX (default 100000; a test knob) symlinks and
#            metadata files, each file at most 1 MiB; over a bound, a file that
#            cannot be read, a symlink loop or a find error is refused as "could not
#            be scanned …" — unknown is never "not bound".
#            .triage-stage-env (a former PYTHONPATH override for bound toolchains)
#            is no longer read: a tracked one is ignored, with a one-line notice on
#            stderr, and lifts nothing.
#            --check: nothing is linked or written and no W is taken; the same rule
#            is applied to R at REV (W's own refusals left out) — what the triage-
#            exec pre-flight asks instead of re-implementing it.
#            Prints one JSON line
#              {"step":"link"|"link-check","worktree"?,"base":"<sha>","links":[P...],
#               "refused":[{"path","reason"}]}
#            Exit 0 (refusals included), 1 when a symlink or the manifest could not
#            be made, an opt-in file could not be read at REV or a git query failed —
#            never "no links" — 2 on a usage error (W not a linked worktree of R, REV
#            not a commit).
#            Absent file = no links. Writes through a link land in R: the leak check
#            sees them like any other ignored-file write, unless .triage-leakignore
#            excludes them.
#
# Exit codes: 0 ok (CLEAN / BASE_MOVED for leakcheck); 1 the step failed (JSON
#             says why); 2 usage error, nothing done; 6 apply: the patch would not
#             apply cleanly, nothing written; 7 LEAK (leakcheck only).
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
REPO="" BASE="" COUNT="" DIR="" WT="" OUT="" PATCH="" REQUIRE_CLEAN=0 LINE=0 CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --require-clean) REQUIRE_CLEAN=1; shift; continue ;;
    --line)          LINE=1; shift; continue ;;
    --check)         CHECK=1; shift; continue ;;
  esac
  [ $# -ge 2 ] || usage "$1 needs a value"
  case "$1" in
    --repo)     REPO="$2" ;;
    --base)     BASE="$2" ;;
    --count)    COUNT="$2" ;;
    --dir)      DIR="$2" ;;
    --worktree) WT="$2" ;;
    --out)      OUT="$2" ;;
    --patch)    PATCH="$2" ;;
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

# snapshot R OUTFILE [PATTERNS] — "<path>\t<blob sha|link:<target>|dir|missing>" for
# every tracked + untracked non-ignored path, sorted, plus ignored_snapshot's
# lines (PATTERNS: the leak exclusions, see there; their count lands in
# OUTFILE.xn). Content-addressed, so it does not depend on HEAD: committing
# leaves it unchanged, editing any file does not.
snapshot() {
  local r="$1" out="$2" pf="${3:-}" p
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
  ignored_snapshot "$r" "$out.ign" "$pf" || return 1
  mv "$out.ign.xn" "$out.xn" || return 1
  { paste "$out.files" "$out.hashes"; cat "$out.other" "$out.ign"; } | sort -u > "$out"
  rm -f "$out.files" "$out.other" "$out.hashes" "$out.ign"
}

# ignored_snapshot R OUTFILE [PATTERNS] — the IGNORED part of the leak fingerprint (the
# `ignored` subcommand prints it; see the header for the rule): IGNORED untracked
# paths of R, bounded: "<path>\tign:<blob sha>" for the first IGN_HASH_MAX files of
# at most IGN_HASH_BYTES, "<path>\tign-meta:<size>:<mtime>" for every other file,
# links and dirs as in snapshot(); shallowest paths first, at most IGN_LIST_MAX
# listed, then one "\tign-count:<count>" line (a change in the count still shows).
# The ONE exclusion list: .claude/ (harness worktrees, agent memory),
# PROJECT_MEMORY*.md and .DS_Store — agents and Finder write them by design while a
# bake-off runs, and they are not the tree. PATTERNS (a file, may be absent or
# empty = none): the repo's .triage-leakignore as committed — IGNORED paths it
# matches are left out too, their count written to OUTFILE.xn, and one
# "\tleakignore:<blob sha>" line added. Only this listing is filtered, so a
# tracked or untracked-not-ignored path can never be excluded.
IGN_HASH_MAX=2000 IGN_HASH_BYTES=262144 IGN_LIST_MAX="${STAGE_WT_IGN_LIST_MAX:-100000}"
case "$IGN_LIST_MAX" in ''|*[!0-9]*) usage "STAGE_WT_IGN_LIST_MAX must be a whole number" ;; esac
ignored_snapshot() {
  local r="$1" out="$2" pf="${3:-}" tab
  tab=$(printf '\t')
  [ -n "$pf" ] && [ -s "$pf" ] || pf=""
  git -C "$r" --no-optional-locks ls-files -z -o -i --exclude-standard > "$out.z" || { rm -f "$out.z"; return 1; }
  : > "$out.x"
  if [ -n "$pf" ]; then
    git -C "$r" --no-optional-locks ls-files -z -o -i --exclude-from="$pf" > "$out.x" || { rm -f "$out.z" "$out.x"; return 1; }
  fi
  # perl lstat()s each path: small files are listed in $out.h for hashing, the rest
  # described by size and mtime. Time::HiRes::lstat is called by its full name: an
  # import at run time comes after `lstat` was compiled to CORE::lstat (whole
  # seconds), so a same-size rewrite within one second would go unseen.
  # shellcheck disable=SC2016  # $vars below are perl's
  ( cd "$r" && perl -e '
      my ($max, $hmax, $hbytes, $hfile, $xfile, $xnfile) = @ARGV; my ($i, $h, $xn) = (0, 0, 0);
      my $hires = eval { require Time::HiRes; defined &Time::HiRes::lstat };
      local $/ = "\0";
      open(my $X, "<", $xfile) or die; my %x = map { chomp; ($_ => 1) } <$X>; close($X);
      open(my $H, ">", $hfile) or die;
      my @p = grep { !m{^\.claude/} && !m{(^|/)PROJECT_MEMORY[^/]*\.md$} && !m{(^|/)\.DS_Store$} }
              map { chomp; $_ } <STDIN>;
      @p = grep { !($x{$_} && ++$xn) } @p;
      open(my $XN, ">", $xnfile) or die; print $XN "$xn\n"; close($XN) or die;
      @p = map { $_->[1] } sort { $a->[0] <=> $b->[0] || $a->[1] cmp $b->[1] } map { [tr{/}{}, $_] } @p;
      for my $p (@p) {
        next if ++$i > $max;
        my @s = $hires ? Time::HiRes::lstat($p) : lstat($p);
        if (!@s) { print "$p\tmissing\n" }
        elsif (-l $p) { print "$p\tlink:" . readlink($p) . "\n" }
        elsif (-d $p) { print "$p\tdir\n" }
        elsif ($h < $hmax && $s[7] <= $hbytes) { $h++; print $H "$p\n" }
        else { print "$p\tign-meta:$s[7]:$s[9]\n" } }
      close($H) or die; print "\tign-count:$i\n" if $i > $max;' "$IGN_LIST_MAX" "$IGN_HASH_MAX" "$IGN_HASH_BYTES" "$out.h" "$out.x" "$out.xn" < "$out.z" ) > "$out.m" ||
    { rm -f "$out.z" "$out.x" "$out.xn" "$out.h" "$out.m"; return 1; }
  : > "$out"
  if [ -s "$out.h" ]; then
    (cd "$r" && git hash-object --no-filters --stdin-paths < "$out.h") > "$out.hh" &&
      [ "$(wc -l < "$out.h")" -eq "$(wc -l < "$out.hh")" ] || { rm -f "$out.z" "$out.x" "$out.xn" "$out.h" "$out.m" "$out.hh"; return 1; }
    paste "$out.h" "$out.hh" | sed "s/$tab/${tab}ign:/" > "$out"
  fi
  cat "$out.m" >> "$out"
  if [ -n "$pf" ]; then
    printf '\tleakignore:%s\n' "$(git hash-object --no-filters -- "$pf")" >> "$out" || { rm -f "$out.z" "$out.x" "$out.xn" "$out.h" "$out.m" "$out.hh"; return 1; }
  fi
  rm -f "$out.z" "$out.x" "$out.h" "$out.m" "$out.hh"
}

# The opt-in per-repo files, all TRACKED at R's root and read at a commit (the
# bake-off's sha; `ignored`: HEAD), never from the working tree. RETIRED_ENV is the
# former stage env: never read, a tracked one only gets a notice (read_grants()).
LEAKIGNORE=.triage-leakignore STAGE_LINKS=.triage-stage-links RETIRED_ENV=.triage-stage-env
# The link manifest: one path per line, every symlink `link` made in a worktree, kept
# in that worktree's own git dir (removed with the worktree).
MANIFEST=triage-stage-links
# The bound-toolchain scan's bound (bound_file()): symlinks + metadata files examined.
BOUND_SCAN_MAX="${STAGE_WT_BOUND_SCAN_MAX:-100000}"
case "$BOUND_SCAN_MAX" in ''|*[!0-9]*) usage "STAGE_WT_BOUND_SCAN_MAX must be a whole number" ;; esac
# rev_file R REV NAME OUT — NAME's content as committed at REV of R into OUT. rc 0
# found; rc 1 legitimately ABSENT (OUT empty): not in REV's tree, or not a regular
# file there (a symlink or a tree is never followed: warned); rc 2 an operational
# FAILURE (OUT not writable, the tree or the blob could not be read) — callers fail
# on it, never read it as "no opt-in". Never the working tree: an uncommitted edit
# cannot widen what it grants.
rev_file() {
  local line mode typ sha rest
  : > "$4" 2>/dev/null || return 2
  line=$(git -C "$1" --no-optional-locks ls-tree "$2" -- "$3" 2>/dev/null) || return 2
  [ -n "$line" ] || return 1
  read -r mode typ sha rest <<< "$line"
  case "$mode $typ" in
    "100644 blob"|"100755 blob") ;;
    *) echo "stage-worktree: $3 at ${2:0:12} is not a regular file (mode $mode) — ignored" >&2; return 1 ;;
  esac
  git -C "$1" cat-file blob "$sha" > "$4" 2>/dev/null || { : > "$4"; return 2; }
}
# read_grants R SHA G — the stage grants at SHA into G.list (.triage-stage-links). rc 1
# when the file could not be READ (rev_file rc 2) — never "no grant". A .triage-stage-env
# tracked at SHA (the retired stage env) is ignored: one notice line on stderr.
read_grants() {
  local rc
  rev_file "$1" "$2" "$STAGE_LINKS" "$3.list"; rc=$?
  [ "$rc" -le 1 ] || { echo "stage-worktree: could not read $STAGE_LINKS at $2" >&2; return 1; }
  if tracked_in "$1" "$2" "$RETIRED_ENV"; then
    echo "stage-worktree: $RETIRED_ENV at ${2:0:12} is ignored — the stage env was retired: links are only for self-contained toolchains, with no reference to the repo" >&2
  fi
  return 0
}
# bound_file R P — the BOUND rule (see `link` in the header) on R/P: prints the refusal
# reason — "imports the source repo: <file relative to R/P> …" for the first reference
# back to R (a metadata file naming R, a .pth/.egg-link path line or a symlink resolving
# into R outside R/P), or "could not be scanned …" when the bounded scan could not finish
# (over BOUND_SCAN_MAX entries, a file over 1 MiB or unreadable, a symlink loop) — and
# nothing when R/P is self-contained. rc != 0 with nothing printed: the scan itself failed
# (find could not walk R/P) — the caller refuses that too. R physical; R/P is never a
# symlink here (refused before).
bound_file() {
  local r="$1" p="$2" alt
  alt=$(git -C "$r" rev-parse --show-toplevel 2>/dev/null) || alt="$r"
  # shellcheck disable=SC2016  # $vars below are perl's
  ( set -o pipefail
    find "$r/$p" \( -type l -o -type f \( -name '*.pth' -o -name '*.egg-link' -o -name direct_url.json -o -name '__editable__*' \) \) -print0 2>/dev/null |
      perl -0e '
        my ($top, $self, $max, @roots) = @ARGV; my $base = "$top/$self";
        my $why = " — links are only for self-contained toolchains: checks would run the repo'\''s code, not the worktree'\''s";
        sub out { print "$_[0]\n"; exit 0 }
        sub err { out("could not be scanned for references to the source repo: $_[0] — refused (unknown is never self-contained)") }
        # phys(P) — P resolved physically: symlinks followed (at most 40), .. taken
        # against the resolved parent, a missing tail appended lexically; undef on a loop.
        sub phys { my ($path, $depth) = @_; return undef if $depth > 40;
          my @c = split m{/}, $path; my $cur = "";
          while (@c) { my $x = shift @c;
            next if $x eq "" || $x eq ".";
            if ($x eq "..") { $cur =~ s{/[^/]*\z}{}; next }
            my $n = "$cur/$x";
            if (-l $n) { my $t = readlink($n); return undef unless defined $t;
              return phys(($t =~ m{^/} ? $t : "$cur/$t") . (@c ? "/" . join("/", @c) : ""), $depth + 1) }
            if (!-e $n) { $cur = $n;
              for my $y (@c) { next if $y eq "" || $y eq "."; if ($y eq "..") { $cur =~ s{/[^/]*\z}{} } else { $cur .= "/$y" } }
              last }
            $cur = $n }
          return $cur eq "" ? "/" : $cur }
        sub inside { my ($a, $b) = @_; return $a eq $b || index($a, "$b/") == 0 }
        my $sp = phys($base, 0); defined $sp or err("$self could not be resolved");
        my $into = sub { my $t = shift; inside($t, $top) && !inside($t, $sp) };
        my %seen; my @alt;
        for my $r (@roots) { next if $seen{$r}++; push @alt, quotemeta($r);
          (my $e = $r) =~ s/([^A-Za-z0-9\/._~-])/sprintf("%%%02X", ord $1)/ge; push @alt, quotemeta($e) if $e ne $r }
        my $rx = join("|", @alt); my $d = q{\s"\x27,;:\]\)\x00}; my $n = 0;
        while (my $f = <STDIN>) { chomp $f;
          err("more than $max symlinks and metadata files under $self") if ++$n > $max;
          my $rel = substr($f, length($base)); $rel =~ s{^/+}{}; $rel = $self if $rel eq "";
          if (-l $f) { my $t = phys($f, 0); defined $t or err("$rel is a symlink loop");
            out("imports the source repo: $rel is a symlink to $t, in the repo outside $self$why") if $into->($t) }
          next unless $f =~ m{(?:\.pth|\.egg-link|/direct_url\.json|/__editable__[^/]*)\z} && -f $f;
          err("$rel is larger than 1 MiB") if -s $f > 1048576;
          open(my $fh, "<", $f) or err("$rel could not be read");
          my $c = ""; defined(read($fh, $c, 1048577)) or err("$rel could not be read"); close($fh);
          err("$rel is larger than 1 MiB") if length($c) > 1048576;
          if ($f !~ m{/direct_url\.json\z} || $c =~ /"editable"\s*:\s*true/) {
            while ($c =~ m{(?:$rx)((?:/[^$d]*)?)(?=\z|[/$d])}g) { my $rest = $1;
              next if $rest eq "/$self" || index($rest, "/$self/") == 0;
              out("imports the source repo: $rel names $top (an editable install)$why") } }
          next unless $f =~ m{\.(?:pth|egg-link)\z};
          # site.py: # lines and blank lines skipped, "import" lines run (not paths), every
          # other line a path, relative to the file'\''s own directory.
          (my $dir = $f) =~ s{/[^/]*\z}{};
          for my $l (split /\n/, $c) { $l =~ s/\s+\z//;
            next if $l eq "" || $l =~ /^#/ || $l =~ /^import[ \t]/;
            my $t = phys($l =~ m{^/} ? $l : "$dir/$l", 0); defined $t or err("$rel: a path line is a symlink loop");
            out("imports the source repo: $rel puts $t on the import path$why") if $into->($t) } }
        exit 0' "$r" "$p" "$BOUND_SCAN_MAX" "$r" "$alt" )
}
# leakignore_json PATTERNS XN — the "leakignore" member: null when PATTERNS is
# absent or empty, else {file, blob, patterns:[non-blank, non-# lines], excluded}.
leakignore_json() {
  if [ ! -s "$1" ]; then echo null; return 0; fi
  jq -nc --arg f "$LEAKIGNORE" --arg b "$(git hash-object --no-filters -- "$1")" --rawfile p "$1" --arg xn "$(cat "$2" 2>/dev/null)" \
    '{file:$f, blob:$b, patterns:($p | split("\n") | map(sub("\r$"; "")) | map(select(length > 0 and (startswith("#") | not)))),
      excluded:($xn | tonumber? // 0)}'
}

status_of() { git -C "$1" --no-optional-locks status --porcelain=v1 -uall; }
fp_get() { sed -n "s/^$1=//p" "$2" | head -n 1; }

# ---------------------------------------------------------------------------
# linked_wt W — W's physical top when W is the root of a LINKED worktree (never a
# main working tree: nothing is ever linked into, or staged from, the real repo);
# rc 1 otherwise.
linked_wt() {
  local top wp gd cdir
  [ -d "$1" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd "$top" && pwd -P) && wp=$(cd "$1" && pwd -P) || return 1
  [ "$top" = "$wp" ] || return 1
  gd=$(cd "$1" && cd "$(git rev-parse --git-dir)" && pwd -P) || return 1
  cdir=$(cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || return 1
  [ "$gd" != "$cdir" ] || return 1
  printf '%s\n' "$wp"
}
common_dir() { (cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P); }

# tracked_in R|W [REV] P — rc 0 when P (or anything under it) is tracked in the index
# of the repo/worktree given (no REV) or in REV's tree; rc 1 when not; rc 2 when git
# failed (a failed query is never "not tracked").
tracked_in() {
  local o
  if [ $# -eq 3 ]; then o=$(git -C "$1" --no-optional-locks ls-tree "$2" -- "$3" 2>/dev/null) || return 2
  else o=$(git -C "$1" --no-optional-locks ls-files -- ":(literal)$2" 2>/dev/null) || return 2
  fi
  [ -n "$o" ]
}
# make_links R SHA W G OUT — the stage-link rule (see `link` in the header) for the
# grants read_grants() left in G (read at SHA): writes the acceptable entries to
# OUT.links (one per line) and the refusals to OUT.refused (JSON lines {path,
# reason}). W non-empty: each is linked W/P -> R/P and recorded in W's manifest; W
# empty (--check): nothing is written and W's own refusals are skipped. R and W
# physical. rc 1 when a link or the manifest could not be made, or a git query failed.
make_links() {
  local r="$1" sha="$2" w="$3" g="$4" out="$5" raw p reason wpar bf brc mf="" failed=0 t
  : > "$out.links" && : > "$out.refused" || return 1
  if [ -n "$w" ]; then
    mf=$(git -C "$w" rev-parse --absolute-git-dir 2>/dev/null) && [ -d "$mf" ] || { echo "stage-worktree: no git dir for $w" >&2; return 1; }
    mf="$mf/$MANIFEST"
  fi
  while IFS= read -r raw || [ -n "$raw" ]; do
    p="${raw%$'\r'}"
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    case "$p" in ''|'#'*) continue ;; esac
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    grep -qxF -- "$p" "$out.links" && continue
    reason=""
    case "$p" in /*) reason="absolute path" ;; esac
    if [ -z "$reason" ]; then
      case "/$p/" in */../*) reason="contains a .. component" ;; */./*|*//*) reason="not a normalized repo-relative path" ;; esac
    fi
    for t in "in the repo" "at the base" "in the worktree's index"; do
      [ -z "$reason" ] || break
      case "$t" in
        "in the repo") tracked_in "$r" "$p" ;;
        "at the base") tracked_in "$r" "$sha" "$p" ;;
        *)             [ -n "$w" ] || continue; tracked_in "$w" "$p" ;;
      esac
      case $? in 0) reason="tracked $t" ;; 1) ;; *) echo "stage-worktree: git could not tell whether $p is tracked $t" >&2; return 1 ;; esac
    done
    if [ -z "$reason" ]; then
      if [ -L "$r/$p" ]; then reason="a symlink in the repo"
      elif [ ! -e "$r/$p" ]; then reason="does not exist in the repo"
      elif ! within "$(cd "$r/$(dirname "$p")" 2>/dev/null && pwd -P)" "$r"; then reason="resolves outside the repo"
      fi
    fi
    if [ -z "$reason" ]; then
      git -C "$r" --no-optional-locks check-ignore -q -- "$p" 2>/dev/null
      case $? in 0) ;; 1) reason="not gitignored in the repo" ;; *) echo "stage-worktree: git check-ignore failed on $p" >&2; return 1 ;; esac
    fi
    # BOUND: links are only for self-contained toolchains — no override (header).
    if [ -z "$reason" ]; then
      bf=$(bound_file "$r" "$p"); brc=$?
      if [ -n "$bf" ]; then reason=$(printf '%s\n' "$bf" | head -n 1)
      elif [ "$brc" -ne 0 ]; then reason="could not be scanned for references to the source repo: the scan failed (find could not walk $p) — refused (unknown is never self-contained)"
      fi
    fi
    if [ -z "$reason" ] && [ -n "$w" ]; then
      if [ -e "$w/$p" ] || [ -L "$w/$p" ]; then reason="already exists in the worktree"
      else
        wpar=$(phys "$w/$(dirname "$p")") || wpar=""
        [ -n "$wpar" ] && within "$wpar" "$w" || reason="its parent resolves outside the worktree"
      fi
    fi
    if [ -n "$reason" ]; then
      jq -nc --arg p "$p" --arg r "$reason" '{path:$p, reason:$r}' >> "$out.refused" || return 1
      continue
    fi
    if [ -n "$w" ]; then
      if ! { mkdir -p "$w/$(dirname "$p")" && ln -s "$r/$p" "$w/$p"; }; then
        echo "stage-worktree: could not link $p into $w" >&2; failed=1; break
      fi
      # Recorded the moment it exists: `diff` keeps exactly the manifest's paths out.
      if ! { grep -qxF -- "$p" "$mf" 2>/dev/null || printf '%s\n' "$p" >> "$mf"; }; then
        echo "stage-worktree: could not record $p in the link manifest $mf" >&2; failed=1; break
      fi
    fi
    printf '%s\n' "$p" >> "$out.links"
  done < "$g.list"
  [ "$failed" -eq 0 ]
}

# stage_links_in W OUT — the stage links of worktree W (physical): the paths of W's
# manifest that are still symlinks, one per line into OUT. Never part of a candidate's
# patch. No manifest = nothing was ever linked (rc 0, OUT empty); a manifest or git dir
# that cannot be read is rc 1 — never "no links".
stage_links_in() {
  local w="$1" out="$2" gd p
  : > "$out" || return 1
  gd=$(git -C "$w" rev-parse --absolute-git-dir 2>/dev/null) && [ -d "$gd" ] || return 1
  [ -e "$gd/$MANIFEST" ] || [ -L "$gd/$MANIFEST" ] || return 0
  cat "$gd/$MANIFEST" > "$out.m" 2>/dev/null || { rm -f "$out.m"; return 1; }
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] && [ -L "$w/$p" ] && printf '%s\n' "$p" >> "$out"
  done < "$out.m"
  rm -f "$out.m"
}

# ---------------------------------------------------------------------------
do_create() {
  [ -n "$REPO" ] && [ -n "$BASE" ] && [ -n "$COUNT" ] && [ -n "$DIR" ] || usage "create needs --repo --base --count --dir"
  case "$COUNT" in ''|*[!0-9]*) usage "--count must be a positive integer" ;; esac
  [ "$COUNT" -ge 1 ] || usage "--count must be a positive integer"
  check_abs --dir "$DIR"
  local R D DL SHA HEAD i made=""
  R=$(repo_top "$REPO") || exit 2   # usage() inside $(...) exits only the subshell
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
  # Every opt-in is read ONCE, at the SHA (never a moving HEAD), and kept: leakcheck
  # uses this copy of the exclusions, and every worktree gets the same grants. A file
  # that cannot be READ is a failure, never "no opt-in".
  local rc
  rev_file "$R" "$SHA" "$LEAKIGNORE" "$D/fingerprint.leakignore"; rc=$?
  [ "$rc" -le 1 ] || { rollback; echo "stage-worktree: could not read $LEAKIGNORE at $SHA" >&2; exit 1; }
  [ -s "$D/fingerprint.leakignore" ] || rm -f "$D/fingerprint.leakignore"
  read_grants "$R" "$SHA" "$D/grants" || { rollback; echo "stage-worktree: could not read the stage grants at $SHA" >&2; exit 1; }
  snapshot "$R" "$D/fingerprint.tree" "$D/fingerprint.leakignore" || { rollback; echo "stage-worktree: could not snapshot $R" >&2; exit 1; }

  i=1
  while [ "$i" -le "$COUNT" ]; do
    if ! git -C "$R" -c core.hooksPath=/dev/null worktree add --detach "$D/wt-$i" "$SHA" > "$D/create.log" 2>&1; then
      echo "stage-worktree: could not create worktree $i at $SHA: $(head -c 400 "$D/create.log")" >&2
      rollback; exit 1
    fi
    made="$made $D/wt-$i"
    make_links "$R" "$SHA" "$D/wt-$i" "$D/grants" "$D/links" || { rollback; exit 1; }
    i=$((i + 1))
  done
  rm -f "$D/create.log"
  if [ -s "$D/links.refused" ]; then
    echo "stage-worktree: $STAGE_LINKS entries NOT linked: $(jq -r '.path + " (" + .reason + ")"' "$D/links.refused" | paste -sd, - | sed 's/,/, /g')" >&2
  fi
  local li
  li=$(leakignore_json "$D/fingerprint.leakignore" "$D/fingerprint.tree.xn") || li=null

  local list=()
  i=1
  while [ "$i" -le "$COUNT" ]; do list+=("$DL/wt-$i"); i=$((i + 1)); done
  jq -nc --arg sha "$SHA" --arg head "$HEAD" --arg repo "$R" --arg fp "$DL/fingerprint" \
    --rawfile links "$D/links.links" --slurpfile refused "$D/links.refused" --argjson li "$li" \
    '{sha:$sha, worktrees:$ARGS.positional, fingerprint:$fp, head:$head, repo:$repo,
      links:($links | split("\n") | map(select(length > 0))), linkRefused:$refused,
      leakignore:$li}' --args "${list[@]}"
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
  # Stage links (`link`, recorded in W's manifest) are the harness's, never the
  # candidate's work: kept out. Any other symlink is the candidate's and stays in.
  local sl lp irc bad=""
  sl=$(mktemp) || diff_fail "mktemp failed"
  stage_links_in "$wp" "$sl" || { rm -f "$sl"; diff_fail "could not read the stage-link manifest of $WT"; }
  git -C "$WT" add -A >/dev/null 2>&1 || { rm -f "$sl"; diff_fail "git add -A failed in $WT"; }
  # Every stage link `add -A` (here, or a candidate's own earlier: `.venv/` does not
  # ignore the symlink FILE .venv) put in the index goes out of it again — the ONE way
  # links are kept out of the patch. A link path is never tracked at the base (`link`
  # refuses it); should one be, it is left as it is.
  while IFS= read -r lp; do
    tracked_in "$WT" "$SHA" "$lp"; irc=$?
    case "$irc" in 0) continue ;; 1) ;; *) bad="git ls-tree failed on the stage link $lp"; break ;; esac
    git -C "$WT" update-index --force-remove -- "$lp" >/dev/null 2>&1 || { bad="could not unstage the stage link $lp in $WT"; break; }
  done < "$sl"
  [ -z "$bad" ] || { rm -f "$sl"; diff_fail "$bad"; }
  git -C "$WT" diff --binary --cached "$SHA" > "$OUT.tmp" 2>/dev/null || { rm -f "$OUT.tmp"; diff_fail "git diff failed in $WT"; }
  mv "$OUT.tmp" "$OUT" || diff_fail "could not write $OUT"
  local stat ign links
  stat=$(git -C "$WT" diff --cached --shortstat "$SHA" 2>/dev/null | sed 's/^ *//')
  # What the patch cannot carry: new files .gitignore keeps out of `add -A`
  # (.parity-env is the harness's own), and nested repos recorded as gitlinks.
  printf '.parity-env\n' >> "$sl"
  ign=$(git -C "$WT" --no-optional-locks ls-files -z -o -i --exclude-standard 2>/dev/null | tr '\000' '\n' | grep -cvxF -f "$sl")
  rm -f "$sl"
  links=$(git -C "$WT" diff --cached --raw -z --no-abbrev --no-renames "$SHA" 2>/dev/null |
    perl -0ne 'chomp; if (/^:\d+ (\d+) /) { $m = $1; $_ = <STDIN>; chomp; print "$_\n" if $m eq "160000" }' |
    jq -R -s -c 'split("\n") | map(select(length > 0))')
  jq -nc --arg w "$WT" --arg p "$OUT" --arg s "$stat" --argjson ign "${ign:-0}" --argjson links "${links:-[]}" \
    '{step:"diff", worktree:$w, patch:$p, ok:true, shortstat:$s, ignoredNew:$ign, gitlinks:$links}'
}

# ---------------------------------------------------------------------------
stage_paths() { # sets R, D from --repo/--dir; refuses overlap
  [ -n "$REPO" ] && [ -n "$DIR" ] || usage "$SUB needs --repo --dir"
  check_abs --dir "$DIR"
  R=$(repo_top "$REPO") || exit 2   # usage() inside $(...) exits only the subshell
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
  # The exclusions create read from HEAD (none for a stage made without them).
  local pf="$D/fingerprint.leakignore" li
  [ -s "$pf" ] || pf=""
  snapshot "$R" "$D/now.tree" "$pf" || { echo "stage-worktree: could not snapshot $R" >&2; exit 1; }
  li=$(leakignore_json "${pf:-/nonexistent}" "$D/now.tree.xn") || li=null
  rm -f "$D/now.tree.xn"
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
  if [ "$li" != null ]; then
    detail="$detail ($(printf '%s' "$li" | jq -r .excluded) ignored path(s) left out by $LEAKIGNORE.)"
  fi
  echo "stage-worktree: $detail" >&2
  local rc=0 json
  [ "$leak" = true ] && rc=7
  json=$(jq -nc --arg st "$status" --argjson leak "$leak" --argjson moved "$moved" --arg sha "$sha" \
    --arg h0 "$h0" --arg h1 "$h1" --rawfile paths "$D/now.paths" --arg d "$detail" --argjson rc "$rc" --argjson line "$LINE" --argjson li "$li" \
    '{step:"leakcheck", status:$st, leak:$leak, baseMoved:$moved, sha:$sha, headBefore:$h0, headAfter:$h1,
      paths:($paths | split("\n") | map(select(length > 0))), detail:$d, leakignore:$li} + (if $line == 1 then {rc:$rc} else {} end)') ||
    { rm -f "$D/now.paths"; echo "stage-worktree: could not build the leakcheck result" >&2; exit 1; }
  if [ "$LINE" -eq 1 ]; then printf 'LEAKCHECK %s\n' "$json"; else printf '%s\n' "$json"; fi
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

# ---------------------------------------------------------------------------
do_ignored() {
  [ -n "$REPO" ] || usage "ignored needs --repo"
  local R tmp
  R=$(repo_top "$REPO") || exit 2   # usage() inside $(...) exits only the subshell
  tmp=$(mktemp -d) || { echo "stage-worktree: mktemp failed" >&2; exit 1; }
  # shellcheck disable=SC2064  # expand now: the temp dir is local to this call
  trap "rm -rf '$tmp'" EXIT
  # HEAD's patterns (none without a HEAD); a file that cannot be READ is exit 1.
  if git -C "$R" rev-parse --verify --quiet HEAD >/dev/null; then
    rev_file "$R" HEAD "$LEAKIGNORE" "$tmp/leakignore"
    [ $? -le 1 ] || { echo "stage-worktree: could not read HEAD:$LEAKIGNORE" >&2; exit 1; }
  else
    : > "$tmp/leakignore"
  fi
  ignored_snapshot "$R" "$tmp/ign" "$tmp/leakignore" || { echo "stage-worktree: could not list the ignored files of $R" >&2; exit 1; }
  if [ -s "$tmp/leakignore" ]; then
    echo "stage-worktree: $(cat "$tmp/ign.xn") ignored path(s) left out by HEAD:$LEAKIGNORE" >&2
  fi
  sort -u "$tmp/ign"
}

# ---------------------------------------------------------------------------
do_link() {
  [ -n "$REPO" ] && [ -n "$BASE" ] || usage "link needs --repo --base and either --worktree W or --check"
  local R W="" SHA tmp step=link
  if [ "$CHECK" -eq 1 ]; then
    [ -z "$WT" ] || usage "link --check takes no --worktree (it links nothing)"
    step=link-check
  else
    [ -n "$WT" ] || usage "link needs --worktree W (or --check)"
    check_abs --worktree "$WT"
  fi
  R=$(repo_top "$REPO") || exit 2   # usage() inside $(...) exits only the subshell
  SHA=$(git -C "$R" rev-parse --verify --quiet "$BASE^{commit}") || usage "--base does not name a commit in $R: $BASE"
  if [ "$CHECK" -eq 0 ]; then
    W=$(linked_wt "$WT") || usage "--worktree is not the root of a linked (staged) worktree: $WT"
    [ "$(common_dir "$W")" = "$(common_dir "$R")" ] || usage "--worktree $WT is not a worktree of $R"
    [ "$W" != "$R" ] || usage "refusing: --worktree is the repo itself"
  fi
  tmp=$(mktemp -d) || { echo "stage-worktree: mktemp failed" >&2; exit 1; }
  # shellcheck disable=SC2064  # expand now: the temp dir is local to this call
  trap "rm -rf '$tmp'" EXIT
  # The grants at the bake-off's sha (the caller's --base), never a moving HEAD.
  read_grants "$R" "$SHA" "$tmp/g" || exit 1
  make_links "$R" "$SHA" "$W" "$tmp/g" "$tmp/l" || exit 1
  if [ -s "$tmp/l.refused" ]; then
    echo "stage-worktree: $STAGE_LINKS entries NOT linked: $(jq -r '.path + " (" + .reason + ")"' "$tmp/l.refused" | paste -sd, - | sed 's/,/, /g')" >&2
  fi
  jq -nc --arg step "$step" --arg w "$WT" --arg sha "$SHA" --rawfile links "$tmp/l.links" --slurpfile refused "$tmp/l.refused" \
    '{step:$step} + (if $step == "link" then {worktree:$w} else {} end) +
     {base:$sha, links:($links | split("\n") | map(select(length > 0))), refused:$refused}' || exit 1
}

# ---------------------------------------------------------------------------
apply_out() { # $1 ok, $2 applied, $3 method, $4 treeModified, $5 error (empty = none)
  jq -nc --arg r "$REPO" --arg p "$PATCH" --argjson ok "$1" --argjson ap "$2" --arg m "$3" --argjson tm "$4" --arg e "$5" \
    '{step:"apply", repo:$r, patch:$p, ok:$ok, applied:$ap, method:$m, treeModified:$tm} + (if $e == "" then {} else {error:$e} end)'
}
# patch_paths R P OUT — every path P touches, one per line: the paths it writes,
# from `git apply --numstat -z` ("A\tD\tPATH\0", or "A\tD\t\0PRE\0POST\0"), plus the
# SOURCE of every rename and copy, from the patch headers (`git apply --numstat`
# prints only the new side of a rename: a dirty source would go unseen and the
# patch land on the caller's edit). Header paths are unquoted as git quotes them.
# rc != 0 when either listing fails: the caller never treats that as clean.
patch_paths() {
  # shellcheck disable=SC2016  # $vars below are perl's
  ( set -o pipefail
    git -C "$1" apply --numstat -z "$2" 2>/dev/null |
      perl -0ne 'chomp; my @f = split(/\t/, $_, 3); if ($f[2] eq "") { for (1, 2) { my $x = <STDIN>; chomp $x; print "$x\n" } } else { print "$f[2]\n" }' || exit 1
    perl -ne '
      my %e = (n => "\n", t => "\t", r => "\r", a => "\a", b => "\b", f => "\f", v => "\013");
      sub unq { my $s = shift; return $s unless $s =~ s/^"(.*)"$/$1/;
        $s =~ s/\\([0-7]{3}|.)/length($1) == 3 ? chr(oct($1)) : exists $e{$1} ? $e{$1} : $1/ge; return $s }
      if (/^diff --git /) { $hd = 1; next }
      if ($hd && /^(?:---|\+\+\+|@@|GIT binary patch|Binary files )/) { $hd = 0; next }
      if ($hd && /^(?:rename|copy) from (.*?)\r?$/) { print unq($1), "\n" }' "$2" || exit 1
  ) | sort -u > "$3"
}
# paths_state R LIST OUT — the index entries (all stages) and the file content of
# every path in LIST: what an apply may change, and nothing else.
paths_state() {
  local r="$1" p
  {
    tr '\n' '\000' < "$2" | xargs -0 git -C "$r" --literal-pathspecs ls-files -s -- 2>/dev/null
    while IFS= read -r p; do
      if [ -L "$r/$p" ]; then printf 'link %s %s\n' "$(readlink "$r/$p")" "$p"
      elif [ -f "$r/$p" ]; then printf '%s %s\n' "$(git -C "$r" hash-object --no-filters -- "$p")" "$p"
      else printf 'absent %s\n' "$p"
      fi
    done < "$2"
  } > "$3"
}
do_apply() {
  [ -n "$REPO" ] && [ -n "$PATCH" ] || usage "apply needs --repo --patch"
  check_abs --patch "$PATCH"
  [ -f "$PATCH" ] || usage "--patch is not a file: $PATCH"
  local R log chk3 tmp dirty paths_ok
  R=$(repo_top "$REPO") || exit 2   # usage() inside $(...) exits only the subshell
  if [ ! -s "$PATCH" ]; then apply_out true false empty false ""; exit 0; fi
  tmp=$(mktemp -d) || { apply_out false false none false "mktemp failed"; exit 1; }
  log="$tmp/log" chk3="$tmp/chk3"
  # shellcheck disable=SC2064  # expand now: the temp dir is local to this call
  trap "rm -rf '$tmp'" EXIT
  paths_ok=1
  patch_paths "$R" "$PATCH" "$tmp/paths" || paths_ok=0
  [ -s "$tmp/paths" ] || paths_ok=0
  if [ "$REQUIRE_CLEAN" -eq 1 ]; then
    if [ "$paths_ok" -eq 0 ]; then
      apply_out false false none false "--require-clean: could not list the paths the patch touches (git apply --numstat / the rename and copy headers), so nothing was written"
      exit 6
    fi
    # A status that FAILS is never clean (its empty output would read as clean).
    if ! tr '\n' '\000' < "$tmp/paths" | xargs -0 git -C "$R" --literal-pathspecs --no-optional-locks status --porcelain=v1 -uall -- > "$tmp/dirty" 2>"$tmp/dirty.err"; then
      apply_out false false none false "--require-clean: git status failed on the paths the patch touches, so nothing was written: $(head -c 300 "$tmp/dirty.err")"
      exit 6
    fi
    dirty=$(head -n 10 "$tmp/dirty" | paste -sd, - | sed 's/,/, /g')
    if [ -n "$dirty" ]; then
      apply_out false false none false "--require-clean: $R has uncommitted changes in path(s) the patch touches ($dirty), so nothing was written"
      exit 6
    fi
  fi
  paths_state "$R" "$tmp/paths" "$tmp/before"
  # A failed write is measured, never assumed: git apply is atomic, a --3way that
  # hits a conflict is not (markers + unmerged index entries).
  # Paths that could not be listed (paths_ok 0): a failed write is never proven harmless.
  modified() { paths_state "$R" "$tmp/paths" "$tmp/after"; if [ "$paths_ok" -eq 1 ] && cmp -s "$tmp/before" "$tmp/after"; then echo false; else echo true; fi; }
  if git -C "$R" apply --check "$PATCH" >"$log" 2>&1; then
    if git -C "$R" apply "$PATCH" >>"$log" 2>&1; then apply_out true true plain true ""; exit 0; fi
    apply_out false false plain "$(modified)" "git apply failed after a clean --check (the tree changed in between?) — inspect $R: $(head -c 300 "$log")"
    exit 1
  fi
  if git -C "$R" apply --3way --check "$PATCH" >"$chk3" 2>&1 && ! grep -qi 'conflict' "$chk3"; then
    if git -C "$R" apply --3way "$PATCH" >>"$log" 2>&1; then apply_out true true 3way true ""; exit 0; fi
    apply_out false false 3way "$(modified)" "the 3-way apply failed after a clean 3-way --check (the tree changed in between?) — inspect $R for conflict markers: $(head -c 300 "$log")"
    exit 1
  fi
  apply_out false false none false "the patch would NOT apply cleanly to $R (plain and 3-way pre-checks failed), so nothing was written: $(cat "$log" "$chk3" | head -c 300)"
  exit 6
}

case "$SUB" in
  apply)     do_apply ;;
  create)    do_create ;;
  diff)      do_diff ;;
  leakcheck) do_leakcheck ;;
  cleanup)   do_cleanup ;;
  ignored)   do_ignored ;;
  link)      do_link ;;
  *)         usage "stage-worktree.sh create|diff|leakcheck|cleanup|apply|ignored|link [options] (see the header)" ;;
esac
