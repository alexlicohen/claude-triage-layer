#!/bin/bash
# Hermetic test suite for scripts/ext-run.sh (the single owner of every external
# CLI invocation: `codex`; the retired `agy` is refused) and for the tiers file
# tooling (config/tiers.json, scripts/tiers-sync.sh, scripts/triage-tiers.sh).
#
# NEVER calls the real Codex CLI and never touches the network: a stub `codex`
# (a shell script) is placed FIRST on PATH, replays canned output chosen by
# $CODEX_STUB_MODE, and logs its cwd, argv, stdin prompt and whether it was
# confined. On macOS every stub run goes through the REAL sandbox-exec profile
# ext-run.sh generates, with HOME pointed at this suite's temp root — so the
# stub lives in, and logs to, $HOME/.codex (the one place outside its workspace
# the profile lets codex read and write), and the P* checks prove the profile
# really denies what it must. Where sandbox-exec does not exist (Linux CI),
# ext-run.sh refuses every codex run; the suite then puts a test double on PATH
# that does NOT confine but forges the preflight canary's denial, so everything
# except real enforcement is still exercised (the P* enforcement checks SKIP).
# Every case runs against its own `mktemp -d` fixture; build cases get their own
# throwaway git repo. Fail-loud: accumulates failures, prints PASS/FAIL per
# check, exits non-zero if anything failed or a prerequisite is missing.
#
# Coverage map:
#   V*      the retired agy vendor is refused (exit 3) before anything runs
#   R*      boundary attestation, deny-list (component / marker / input), usage
#           errors, the 256KB prompt guard, stage containment
#   B*      build mode: the disposable worktree, carrying uncommitted and
#           untracked work in, the patch applied back, the apply-conflict exit
#           code, worktree/stage removal, an untouched real tree whenever the run
#           did not pass its gates
#   P*      OS confinement: sandbox-exec and --dangerously-bypass only together,
#           real enforcement (workspace r/w, $HOME reads/writes, deny-by-default
#           writes outside $HOME and the temp dirs, temp-dir reads — sibling
#           stages, patches, Claude scratchpads, the per-user temp dir —,
#           --allow-read, the private meta dir, the real repo in build mode, what
#           zsh/git/python3/a PTY need), the generated profile, fail-closed
#           (missing / not applying / not enforcing, either preflight canary)
#   A*      --allow-read refusals and the prompt footer
#   I*      --input-dir: a whole tree copied into the stage, refused when a link
#           leaves it or a deny-listed repo / marker lies in or above it, the size
#           cap, read-only modes only
#   L*      the command audit log (fields, no output, failed runs, prune, dir)
#   T*      tiers.json: ids come from the file, lookup order, missing or
#           unparseable file, absent entry = refusal, vendor/model mismatch
#   C*      codex: the flag table per mode, every result gate, the watchdog,
#           deny-list/markers, linked worktrees, --patch-out and --check
#   Y*      tiers-sync.sh (frontmatter <-> tiers.json) and triage-tiers.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXT_RUN="$REPO_DIR/scripts/ext-run.sh"

for tool in jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "INCOMPLETE: $tool is required to run this suite — cannot verify ext-run.sh." >&2
    exit 1
  fi
done
[ -x "$EXT_RUN" ] || { echo "INCOMPLETE: $EXT_RUN is missing or not executable." >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
ALL_TMP=""

cleanup() {
  # shellcheck disable=SC2086
  [ -n "$ALL_TMP" ] && rm -rf $ALL_TMP
}
trap cleanup EXIT

# Hermetic root: every fixture lives under ROOT, and HOME=ROOT, so the deny walk
# (path up to AND INCLUDING $HOME) never reaches a machine-level marker, and the
# sandbox profile's $HOME rules apply to ROOT. Cases that test the $HOME rule set
# their own HOME per call. Removing ROOT removes every fixture.
ROOT=$(mktemp -d)
ROOT=$(cd "$ROOT" && pwd -P)
ALL_TMP="$ROOT"
export HOME="$ROOT"
export TMPDIR="$ROOT/tmp"
mkdir -p "$TMPDIR"

new_tmp() { # under ROOT (a bare `mktemp -d` ignores $TMPDIR on macOS)
  d=$(mktemp -d "$ROOT/t.XXXXXX")
  printf '%s' "$d"
}

# chk NAME CONDITION — CONDITION is a shell test string passed to `eval`.
chk() {
  name="$1"
  cond="$2"
  if eval "$cond"; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    echo "      rc=$RC"
    [ -n "$ERR" ] && echo "      stderr: $(printf '%s' "$ERR" | head -3)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}
skip() { echo "SKIP: $1 ($2)"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# --- the OS sandbox this platform offers --------------------------------------
HARNESS=$(new_tmp)
REAL_SANDBOX=0
# shellcheck disable=SC2034  # EXPECT_SBX is read inside chk's eval'd condition strings
EXPECT_SBX="fake"
if [ "$(uname -s)" = Darwin ]; then
  if ! type -P sandbox-exec >/dev/null 2>&1; then
    echo "INCOMPLETE: macOS without sandbox-exec on PATH — cannot verify the codex confinement." >&2
    exit 1
  fi
  REAL_SANDBOX=1
  # shellcheck disable=SC2034  # read inside chk's eval'd condition strings
  EXPECT_SBX="yes"
else
  # No sandbox-exec here: ext-run.sh refuses every codex run (exit 4). This
  # double does NOT confine; it forges the preflight canary's denial so the
  # non-confinement paths still run. Real enforcement is proven on macOS only.
  FAKE_SBX_DIR="$HARNESS/fake-sbx"
  mkdir -p "$FAKE_SBX_DIR"
  cat > "$FAKE_SBX_DIR/sandbox-exec" <<'FAKE'
#!/bin/sh
[ "$1" = -f ] && [ -s "$2" ] || { echo "fake sandbox-exec: expected -f PROFILE" >&2; exit 64; }
shift 2
for a in "$@"; do case "$a" in */.sandbox-canary) exit 0 ;; esac; done
FAKE_SANDBOX_EXEC=1
export FAKE_SANDBOX_EXEC
exec "$@"
FAKE
  chmod +x "$FAKE_SBX_DIR/sandbox-exec"
  PATH="$FAKE_SBX_DIR:$PATH"
  echo "NOTE: no sandbox-exec on $(uname -s): codex runs use a NON-confining test double; the P* enforcement checks are skipped."
fi

# --- the stub `codex` -------------------------------------------------------
# It lives in $HOME/.codex/bin: the sandbox lets codex read (and write) only
# $HOME/.codex, its workspace and its scratch dir under $HOME.
STUB_BIN="$ROOT/.codex/bin"
mkdir -p "$STUB_BIN"
STUB_LOG="$ROOT/.codex/stub.log"
STUB_PROMPT="$ROOT/.codex/stub-prompt.txt"
ALL_STUB_LOG="$HARNESS/all-stub.log"
: > "$ALL_STUB_LOG"
ERRF="$HARNESS/stderr.txt"

cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/bash
# Stub Codex CLI. Replays canned JSONL events; never talks to anything.
set -u
LOG="${CODEX_STUB_LOG:-$HOME/.codex/stub.log}"
log() { printf '%s\n' "$1" >> "$LOG"; }
log "SELF=$0"
log "PWD=$PWD"
log "GITTOP=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
if [ -e "$PWD/.git" ]; then log "DOTGIT=present"; else log "DOTGIT=absent"; fi
# Confined? A write to $HOME must be denied by the real profile; the Linux test
# double announces itself instead.
if [ "${FAKE_SANDBOX_EXEC:-}" = 1 ]; then log "SANDBOXED=fake"
elif ( : > "$HOME/.sbx-check.$$" ) 2>/dev/null; then rm -f "$HOME/.sbx-check.$$"; log "SANDBOXED=no"
else log "SANDBOXED=yes"; fi
log "TMPDIR=${TMPDIR:-}"
last=""
prev=""
for a in "$@"; do
  log "ARG=$a"
  case "$prev" in
    -C) log "CDIR=$a" ;;
    -s) log "SANDBOX=$a" ;;
    -m) log "MODEL=$a" ;;
    -c) log "CFG=$a" ;;
    -o) last="$a" ;;
    --output-schema) log "OSCHEMA=$(cat "$a" 2>/dev/null)" ;;
  esac
  prev="$a"
done
log "LASTARG=$prev"
cat > "${CODEX_STUB_PROMPT:-$HOME/.codex/stub-prompt.txt}"
for probe in dirty.txt new.txt calc.txt sub/deep.txt .codex-inputs/note.txt; do
  [ -f "$PWD/$probe" ] && log "SEEN $probe=$(head -1 "$PWD/$probe")"
done
ok_events() {
  echo '{"type":"thread.started","thread_id":"t-1"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"done"}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":12}}'
}
fail_events() {
  echo '{"type":"thread.started","thread_id":"t-1"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"turn.failed","error":{"message":"stream disconnected"}}'
  echo '{"type":"error","message":"stream disconnected"}'
}
cmd_events() { # two commands (the second over 500 chars, exit 2) + their output
  long="echo $(printf '%0700d' 0 | tr 0 x)"
  echo '{"type":"thread.started","thread_id":"t-1"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"bash -lc ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}'
  echo '{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"bash -lc ls","aggregated_output":"SECRET-OUTPUT a.txt","exit_code":0,"status":"completed"}}'
  printf '{"type":"item.completed","item":{"id":"c2","type":"command_execution","command":"%s","aggregated_output":"SECRET-OUTPUT","exit_code":2,"status":"failed"}}\n' "$long"
}
case "${CODEX_STUB_MODE:-ok}" in
  ok)        ok_events; printf 'hello from codex\n' > "$last" ;;
  empty)     ok_events; : > "$last" ;;
  failed)    fail_events; exit 1 ;;
  failedrc0) fail_events; printf 'partial\n' > "$last" ;;
  exit7)     ok_events; printf 'x\n' > "$last"; exit 7 ;;
  schemaok)  ok_events; printf '{"verdict":"clean"}\n' > "$last" ;;
  schemabad) ok_events; printf 'not json at all\n' > "$last" ;;
  write)
    printf 'sneaky\n' > "$PWD/sneaky.txt"
    ok_events; printf 'wrote a file\n' > "$last" ;;
  cmds)      cmd_events; ok_events; printf 'ran commands\n' > "$last" ;;
  cmdsfail)  cmd_events; fail_events; exit 1 ;;
  buildedit)
    printf 'CODEX WAS HERE\n' >> "$PWD/calc.txt"
    printf 'generated\n' > "$PWD/gen.txt"
    ok_events; printf 'edited calc.txt\nDONE exit=0\n' > "$last" ;;
  buildnoop) ok_events; printf 'nothing to do\nDONE exit=0\n' > "$last" ;;
  buildconflict)
    # Edit line 2 of the staged copy; the caller's tree drifts on the same line
    # afterwards (the case's --check does it, outside the sandbox).
    printf 'line1\nSTAGE\nline3\n' > "$PWD/conflict.txt"
    ok_events; printf 'edited conflict.txt\nDONE exit=0\n' > "$last" ;;
  build3way)
    printf 'EDIT1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$PWD/long.txt"
    ok_events; printf 'edited long.txt\nDONE exit=0\n' > "$last" ;;
  buildmkgit)
    # The CLI makes a git repo of its own in the workspace, and edits a file.
    git init -q "$PWD" >/dev/null 2>&1
    printf 'CODEX WAS HERE\n' >> "$PWD/calc.txt"
    ok_events; printf 'edited calc.txt\nDONE exit=0\n' > "$last" ;;
  probe)
    # What the sandbox lets it do — results land in the workspace.
    {
      if printf 'rw\n' > "$PWD/rw.txt" 2>/dev/null && [ "$(cat "$PWD/rw.txt" 2>/dev/null)" = rw ]; then echo "ws-rw=ok"; else echo "ws-rw=denied"; fi
      if s=$(cat "$HOME/projects/secret/secret.txt" 2>/dev/null); then echo "home-read=ok:$s"; else echo "home-read=denied"; fi
      if ( : > "$HOME/x" ) 2>/dev/null; then echo "home-write=ok"; else echo "home-write=denied"; fi
      if ( : > "$CODEX_STUB_TMPPROBE" ) 2>/dev/null; then echo "tmp-write=ok"; else echo "tmp-write=denied"; fi
      if s=$(cat "$CODEX_STUB_ALLOWED/ok.txt" 2>/dev/null); then echo "allowed-read=ok:$s"; else echo "allowed-read=denied"; fi
      if ( : > "$(dirname "$PWD")/meta/tamper.txt" ) 2>/dev/null; then echo "meta-write=ok"; else echo "meta-write=denied"; fi
      if printf 't\n' > "$TMPDIR/t.txt" 2>/dev/null; then echo "tmpdir-write=ok"; else echo "tmpdir-write=denied"; fi
      # Outside $HOME and the temp dirs: only deny-by-default stands in the way.
      o="$CODEX_STUB_OUTSIDE"
      if ( : > "$o/w.txt" ) 2>/dev/null; then echo "outside-write=ok"; else echo "outside-write=denied"; fi
      if mkdir "$o/d" 2>/dev/null; then echo "outside-mkdir=ok"; else echo "outside-mkdir=denied"; fi
      if ln -s /etc/hosts "$o/sl" 2>/dev/null; then echo "outside-symlink=ok"; else echo "outside-symlink=denied"; fi
      if printf 'm\n' > "$PWD/mv.txt" 2>/dev/null && mv "$PWD/mv.txt" "$o/mv.txt" 2>/dev/null; then echo "outside-rename=ok"; else echo "outside-rename=denied"; fi
      if ln "$o/target.txt" "$PWD/hl.txt" 2>/dev/null && printf 'POISON\n' >> "$PWD/hl.txt" 2>/dev/null; then echo "hardlink-write=ok"; else echo "hardlink-write=denied"; fi
      if [ -d /Users/Shared ]; then
        if ( : > "/Users/Shared/.ext-run-probe.$CODEX_STUB_RUNTAG" ) 2>/dev/null; then echo "shared-write=ok"; else echo "shared-write=denied"; fi
      fi
      if ( : > "$CODEX_STUB_ALLOWED/w.txt" ) 2>/dev/null; then echo "allowed-write=ok"; else echo "allowed-write=denied"; fi
      if ( : > /dev/null ) 2>/dev/null; then echo "devnull-write=ok"; else echo "devnull-write=denied"; fi
      if ( : >> /dev/stderr ) 2>/dev/null; then echo "devfd-write=ok"; else echo "devfd-write=denied"; fi
    } > "$PWD/probe.txt" 2>/dev/null
    ok_events; printf 'probed\n' > "$last" ;;
  probetmp)
    # Stage under a /private/tmp fixture, $HOME elsewhere: only the profile's
    # temp-dir read rule stands between codex and a sibling stage, a Claude
    # scratchpad or the per-user temp dir. Then what a login zsh, git, python3
    # and a PTY need inside the sandbox.
    {
      if s=$(cat "$PWD/inputs/note.txt" 2>/dev/null); then echo "ws-read=ok:$s"; else echo "ws-read=denied"; fi
      if s=$(cat "$CODEX_STUB_SIBLING" 2>/dev/null); then echo "sibling-read=ok:$s"; else echo "sibling-read=denied"; fi
      if s=$(cat "$CODEX_STUB_SIBPATCH" 2>/dev/null); then echo "sibpatch-read=ok:$s"; else echo "sibpatch-read=denied"; fi
      if ls "$(dirname "$(dirname "$PWD")")" >/dev/null 2>&1; then echo "stage-parent-list=ok"; else echo "stage-parent-list=denied"; fi
      if s=$(cat "$CODEX_STUB_SCRATCH" 2>/dev/null); then echo "scratch-read=ok:$s"; else echo "scratch-read=denied"; fi
      if s=$(cat "$CODEX_STUB_VF" 2>/dev/null); then echo "varfolders-read=ok:$s"; else echo "varfolders-read=denied"; fi
      if s=$(cat "$(dirname "$PWD")/meta/prompt.txt" 2>/dev/null); then echo "meta-read=ok"; else echo "meta-read=denied"; fi
      if s=$(cat "$CODEX_STUB_ALLOWED/ok.txt" 2>/dev/null); then echo "allowed-read=ok:$s"; else echo "allowed-read=denied"; fi
      if git init -q "$PWD/g" 2>/dev/null && [ "$(git -C "$PWD/g" rev-parse --show-toplevel 2>/dev/null)" = "$PWD/g" ] &&
         git -C "$PWD/g" -c user.email=p@localhost -c user.name=p commit -q --allow-empty -m p 2>/dev/null; then echo "git=ok"; else echo "git=denied"; fi
      if [ "$(zsh -lc 'echo zok' 2>/dev/null)" = zok ]; then echo "zsh-login=ok"; else echo "zsh-login=denied"; fi
      if [ -n "${CODEX_STUB_PY:-}" ]; then
        if [ "$(python3 -c 'import os, tempfile; tempfile.TemporaryFile().write(b"x"); print(os.path.realpath("."))' 2>/dev/null)" = "$PWD" ]; then echo "python=ok"; else echo "python=denied"; fi
      fi
      if script -q /dev/null true </dev/null >/dev/null 2>&1; then echo "pty=ok"; else echo "pty=denied"; fi
      e=$( ( : > /dev/tty ) 2>&1 )
      case "$e" in *"not permitted"*) echo "tty-open=denied" ;; *) echo "tty-open=ok" ;; esac
    } > "$PWD/probe.txt" 2>/dev/null
    ok_events; printf 'probed\n' > "$last" ;;
  probebuild)
    # Build mode with the caller's repo OUTSIDE $HOME: only the profile's
    # repo rule stands between codex and it. Results go into the patch.
    {
      if cat "$CODEX_STUB_REPO/calc.txt" >/dev/null 2>&1; then echo "repo-read=ok"; else echo "repo-read=denied"; fi
      if cat "$CODEX_STUB_REPO/.git/HEAD" >/dev/null 2>&1; then echo "gitdir-read=ok"; else echo "gitdir-read=denied"; fi
      if ( printf 'gitdir: /nowhere\n' > "$(dirname "$PWD")/meta/worktree.git" ) 2>/dev/null; then echo "hidden-git-write=ok"; else echo "hidden-git-write=denied"; fi
    } > "$PWD/probe.txt" 2>/dev/null
    ok_events; printf 'probed\nDONE exit=0\n' > "$last" ;;
  hang) exec sleep 30 ;;
  hanggc)
    # A grandchild that IGNORES TERM, then the CLI hangs: the watchdog's TERM
    # kills the parent, and only a tree/group KILL can reach the grandchild.
    ( trap '' TERM; exec sleep 300 ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "$CODEX_STUB_GC"
    exec sleep 30 ;;
  okgc)
    # A normal run that leaves a background grandchild behind.
    sleep 300 </dev/null >/dev/null 2>&1 &
    echo "$!" > "$CODEX_STUB_GC"
    ok_events; printf 'hello from codex\n' > "$last" ;;
  *) echo "stub: unknown CODEX_STUB_MODE '${CODEX_STUB_MODE:-}'" >&2; exit 9 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/codex"

# stub_home DIR — the stub copied into DIR/.codex/bin, for a case that runs with
# HOME=DIR: under any other $HOME the sandbox cannot read (so cannot exec) the
# stub in ROOT, which sits in the temp dirs. Prints the copy's path (CODEX_BIN).
stub_home() {
  mkdir -p "$1/.codex/bin"
  cp "$STUB_BIN/codex" "$1/.codex/bin/codex"
  printf '%s' "$1/.codex/bin/codex"
}

# Fixtures the $HOME rule does not cover. OUTSIDE is also outside the temp dirs
# (/private/var/tmp; /var/tmp off macOS): only the profile's deny-by-default write
# rule and its build-mode repo rule stand between codex and it. TP is under the
# REAL /private/tmp (/tmp off macOS): only the temp-dir read rule covers it.
XVAR=/private/var/tmp; [ -d "$XVAR" ] || XVAR=/var/tmp
XTMP=/private/tmp; [ -d "$XTMP" ] || XTMP=/tmp
OUTSIDE=$(mktemp -d "$XVAR/ext-run-test.XXXXXX") && OUTSIDE=$(cd "$OUTSIDE" && pwd -P) || OUTSIDE=""
TP=$(mktemp -d "$XTMP/ext-run-test.XXXXXX") && TP=$(cd "$TP" && pwd -P) || TP=""
ALL_TMP="$ALL_TMP $OUTSIDE $TP"
if [ -z "$OUTSIDE" ] || [ -z "$TP" ]; then
  echo "INCOMPLETE: could not create the fixtures under $XVAR and $XTMP." >&2
  exit 1
fi

PATH="$STUB_BIN:$PATH"
export PATH
export CODEX_STUB_LOG="$STUB_LOG"
export CODEX_STUB_PROMPT="$STUB_PROMPT"
# Hermetic git: the caller's ~/.gitconfig (hooks, gpgsign, templates) must not
# reach either the fixtures or ext-run.sh's own worktree/commit calls.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

OUT=""; ERR=""; RC=0
run_ext() { # run ext-run.sh, capture stdout/stderr/exit
  : > "$STUB_LOG"
  : > "$STUB_PROMPT"
  # shellcheck disable=SC2034  # OUT is read inside chk's eval'd condition strings
  OUT=$("$EXT_RUN" "$@" 2>"$ERRF")
  RC=$?
  ERR=$(cat "$ERRF")
  cat "$STUB_LOG" >> "$ALL_STUB_LOG"
}
kept_stage() { printf '%s' "$ERR" | sed -n 's/^ext-run: staging dir kept at //p' | head -1; }

PROMPTS=$(new_tmp)
BRIEF="$PROMPTS/brief.txt"
printf 'Do the thing.\n' > "$BRIEF"
DATA="$PROMPTS/note.txt"
printf 'needle\n' > "$DATA"

new_repo() { # $1 = path; a git repo with one commit
  mkdir -p "$1"
  git -c init.defaultBranch=main init -q "$1"
  git -C "$1" config user.email ext-test@localhost
  git -C "$1" config user.name ext-test
  printf 'line1\nline2\nline3\n' > "$1/calc.txt"
  printf 'line1\nline2\nline3\n' > "$1/conflict.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}
wt_count() { git -C "$1" worktree list | wc -l | tr -d ' '; }

# --- tiers fixture (codex model ids come from the file, never the script) -------
FIX="$HARNESS/tiers-fixture.json"
cat > "$FIX" <<'FIXTURE'
{
  "asOf": "fixture",
  "parity": [{"date": "2000-01-01", "by": "test", "note": "old note"},
             {"date": "2000-02-02", "by": "test", "note": "fixture parity note"}],
  "levels": {
    "builder": {"claude": {"agent": "triage-builder", "model": "sonnet", "effort": "medium"},
                "codex": {"model": "gpt-fx-builder", "effort": "medium", "basis": "guess"}},
    "deep": {"codex": {"model": "gpt-fx-deep", "effort": "high"}}
  },
  "modes": {
    "codex": {"review": {"model": "gpt-fx-review", "effort": "high"},
              "read": {"model": "gpt-fx-read", "effort": "low"},
              "verify": {"model": "gpt-fx-verify", "effort": "medium"},
              "critique": {"model": "gpt-fx-crit"}}
  }
}
FIXTURE
# A tiers file that still carries retired agy entries: they must not revive it.
FIX_AGY="$HARNESS/tiers-fixture-agy.json"
jq '.modes.agy = {"review": {"model": "gemini-3.1-pro-high"}} | .levels.builder.agy = {"model": "gemini-3.1-pro-high"}' "$FIX" > "$FIX_AGY"

echo "=== ext-run.sh — hermetic suite (stub codex, no network; sandbox: $([ "$REAL_SANDBOX" -eq 1 ] && echo real || echo test double)) ==="

# --- S0: the stub, not the real CLI, is what will run -----------------------
RC=0; ERR=""
chk "S0 the stub codex is first on PATH (no real CLI can be reached)" \
  '[ "$(command -v codex)" = "$STUB_BIN/codex" ]'

# --- V*: agy is retired ---------------------------------------------------------
AGY_BOUNDARY_CLEARED=1 run_ext review --vendor agy --prompt-file "$BRIEF"
chk "V1 --vendor agy is REFUSED (exit 3, 'agy retired 2026-09-24'), nothing runs" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "agy retired 2026-09-24" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX_AGY" run_ext review --vendor agy --prompt-file "$BRIEF"
chk "V1b ...even when the tiers file still lists agy entries" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "agy retired 2026-09-24" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 run_ext build --vendor agy --level builder --prompt-file "$BRIEF" --workdir "$PROMPTS"
chk "V1c ...in build mode too, before any workdir/level validation" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "agy retired" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 run_ext review --vendor gemini --prompt-file "$BRIEF"
chk "V2 an unknown --vendor is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "unknown --vendor"'

# --- R*: refusals and usage errors ---------------------------------------------
AGY_BOUNDARY_CLEARED="" run_ext read --prompt-file "$BRIEF"
chk "R1 missing AGY_BOUNDARY_CLEARED refuses before anything runs (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "REFUSED" && [ ! -s "$STUB_LOG" ]'

DENY=$(new_tmp)
mkdir -p "$DENY/clip-creator/inner"
new_repo "$DENY/clip-creator/inner"
AGY_BOUNDARY_CLEARED=1 run_ext build --level builder --prompt-file "$BRIEF" --workdir "$DENY/clip-creator/inner"
chk "R2 a path component equal to a deny-listed repo refuses (exit 3, names clip-creator)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'

mkdir -p "$DENY/clip-creators-lab"
new_repo "$DENY/clip-creators-lab"
AGY_BOUNDARY_CLEARED=1 run_ext build --level builder --prompt-file "$BRIEF" --workdir "$DENY/clip-creators-lab" --output "$DENY/out.patch"
chk "R3 clip-creators-lab is NOT refused — component equality, not substring" \
  '[ "$RC" -ne 3 ] && ! printf "%s" "$ERR" | grep -q "REFUSED"'

# Regression: engram left the deny-list on 2026-09-15 (its content is already on
# Google Drive), so a path under it must now run like any other repo.
mkdir -p "$DENY/engram/notes"
new_repo "$DENY/engram/notes"
AGY_BOUNDARY_CLEARED=1 run_ext build --level builder --prompt-file "$BRIEF" --workdir "$DENY/engram/notes" --output "$DENY/out-engram.patch"
chk "R3b engram is NOT deny-listed any more (2026-09-15) — a path under it runs" \
  '[ "$RC" -ne 3 ] && ! printf "%s" "$ERR" | grep -q "REFUSED"'

MARKED=$(new_tmp)
new_repo "$MARKED/repo"
: > "$MARKED/repo/.codex-deny"
AGY_BOUNDARY_CLEARED=1 run_ext build --level builder --prompt-file "$BRIEF" --workdir "$MARKED/repo"
chk "R4 a .codex-deny marker in the tree refuses (exit 3, names the marker)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny" && [ ! -s "$STUB_LOG" ]'

mkdir -p "$DENY/clip-creator"
cp "$DATA" "$DENY/clip-creator/note.txt"
AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$BRIEF" --input "$DENY/clip-creator/note.txt"
chk "R4b --input from a deny-listed repo refuses (exit 3, names clip-creator)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'

AMARK=$(new_tmp)
new_repo "$AMARK/repo"
: > "$AMARK/repo/.agy-deny"
git -C "$AMARK/repo" add .agy-deny && git -C "$AMARK/repo" commit -qm marker
AGY_BOUNDARY_CLEARED=1 CODEX_STUB_MODE=buildnoop run_ext build --level builder --prompt-file "$BRIEF" --workdir "$AMARK/repo" --output "$AMARK/codex.patch"
chk "R4c a leftover .agy-deny marker is inert now that agy is retired (codex runs, exit 0)" '[ "$RC" -eq 0 ]'

AGY_BOUNDARY_CLEARED=1 run_ext nonsense --prompt-file "$BRIEF"
chk "R5 unknown mode is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "unknown mode"'

AGY_BOUNDARY_CLEARED=1 run_ext review --prompt-file "$BRIEF" --schema '{"type":"object"}'
chk "R6 --schema outside read mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$BRIEF" --workdir "$PROMPTS"
chk "R7 --workdir outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 run_ext build --level builder --prompt-file "$BRIEF"
chk "R8 build without --workdir is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 run_ext review --prompt-file "$BRIEF" --model claude-opus-4-6-thinking
chk "R9 a Claude model is refused — the tier is cross-vendor by definition (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -qi "claude"'

BIG="$PROMPTS/big.txt"
: > "$BIG"
i=0
while [ "$i" -lt 3200 ]; do
  printf '%s\n' "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789" >> "$BIG"
  i=$((i + 1))
done
AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$BIG"
chk "R10 a >256KB prompt file is refused and names --input (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q -- "--input"'

AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$BRIEF" --output "$PROMPTS/x.patch"
chk "R10b --output outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$PROMPTS/no-such-file.txt"
chk "R10c a missing prompt file is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "not found"'

# --- C1: a good read-only run — the flag table and the confinement pairing -------
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok \
  run_ext read --prompt-file "$BRIEF" --input "$DATA"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_PWD=$(grep '^PWD=' "$STUB_LOG" | head -1 | sed 's/^PWD=//')
chk "C1 a good codex run (default vendor) exits 0 and stdout is exactly the -o final message" \
  '[ "$RC" -eq 0 ] && [ "$OUT" = "hello from codex" ]'
chk "C1b codex exec, model + effort from the FIXTURE tiers file" \
  '[ "$(grep "^ARG=" "$STUB_LOG" | head -1)" = "ARG=exec" ] && grep -qx "MODEL=gpt-fx-read" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=low" "$STUB_LOG"'
chk "P0 --dangerously-bypass-approvals-and-sandbox is passed only UNDER sandbox-exec (the stub ran confined)" \
  'grep -qx -- "ARG=--dangerously-bypass-approvals-and-sandbox" "$STUB_LOG" && grep -qx "SANDBOXED=$EXPECT_SBX" "$STUB_LOG"'
chk "P0b codex's own sandbox flags are gone: no -s, no sandbox_workspace_write.* config, no other --dangerously-* flag" \
  '! grep -q "^SANDBOX=" "$STUB_LOG" && ! grep -qx -- "ARG=-s" "$STUB_LOG" && ! grep -q "sandbox_workspace_write" "$STUB_LOG" && [ "$(grep -c -- "^ARG=--dangerously" "$STUB_LOG")" -eq 1 ]'
chk "C1d --ephemeral --skip-git-repo-check --ignore-user-config --json, prompt on stdin (-)" \
  'grep -qx -- "ARG=--ephemeral" "$STUB_LOG" && grep -qx -- "ARG=--skip-git-repo-check" "$STUB_LOG" && grep -qx -- "ARG=--ignore-user-config" "$STUB_LOG" && grep -qx -- "ARG=--json" "$STUB_LOG" && grep -qx -- "LASTARG=-" "$STUB_LOG"'
chk "C1e no web search outside verify" '! grep -q "web_search" "$STUB_LOG"'
chk "C1f -C pins the throwaway stage, which is also the process cwd" \
  '[ "$(grep "^CDIR=" "$STUB_LOG" | sed "s/^CDIR=//")" = "$STUB_PWD" ] && case "$STUB_PWD" in */ext-run.*/ws) true ;; *) false ;; esac'
chk "C1g the stdin prompt carries the Workspace footer, the staged input and the non-interactive footer" \
  'grep -q -- "--- Workspace ---" "$STUB_PROMPT" && grep -q "^  /.*/inputs/note.txt$" "$STUB_PROMPT" && grep -q -- "--- Non-interactive worker ---" "$STUB_PROMPT" && grep -q "PROJECT_MEMORY.md" "$STUB_PROMPT"'
chk "C1g2 ...and says filesystem access is limited to the workspace" \
  'grep -qx "Your filesystem access is limited to this workspace; other paths will fail - do not search the disk." "$STUB_PROMPT"'
chk "C1h the token line is input+output from turn.completed, tagged codex/<model>, out= the output tokens (reasoning inside)" \
  'printf "%s" "$ERR" | grep -q "^ext-run: 130 tokens ([0-9]*s, codex/gpt-fx-read) out=30$"'
chk "C1i codex's TMPDIR is its private scratch dir inside the stage" \
  'grep -q "^TMPDIR=.*/ext-run\.[^/]*/cx/tmp$" "$STUB_LOG"'
chk "C1j a clean read-only run prints NO staging-write note" \
  '! printf "%s" "$ERR" | grep -q "wrote into its staging dir"'

# The binary is the real FILE codex names — never a shell function, and a
# symlink is followed to its target.
codex() { : > "$ROOT/function-ran"; }
export -f codex
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF"
unset -f codex
chk "C0b an exported shell function named codex is never what runs (the PATH file is)" \
  '[ "$RC" -eq 0 ] && [ ! -e "$ROOT/function-ran" ] && grep -qx "SELF=$STUB_BIN/codex" "$STUB_LOG"'
LINKS="$ROOT/.codex/links"; mkdir -p "$LINKS"; ln -s "$STUB_BIN/codex" "$LINKS/codex-link"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok CODEX_BIN="$LINKS/codex-link" run_ext read --prompt-file "$BRIEF"
chk "C0c CODEX_BIN is honored and resolved to its real file (a symlink runs its target)" \
  '[ "$RC" -eq 0 ] && grep -qx "SELF=$STUB_BIN/codex" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=write run_ext review --prompt-file "$BRIEF"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_PWD=$(grep '^PWD=' "$STUB_LOG" | head -1 | sed 's/^PWD=//')
chk "R19c a read-only run that writes is contained AND reported, never silent" \
  '[ "$RC" -eq 0 ] && printf "%s" "$ERR" | grep -q "wrote into its staging dir"'
chk "R19d the staging dir is gone after exit (nothing codex wrote survives)" \
  '[ ! -e "$STUB_PWD" ]'

AGY_BOUNDARY_CLEARED=1 AGY_STAGE_KEEP=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input "$DATA"
KEPT=$(kept_stage)
chk "R21b AGY_STAGE_KEEP=1 keeps the stage and its meta/prompt.txt for inspection" \
  '[ -n "$KEPT" ] && [ -f "$KEPT/meta/prompt.txt" ] && grep -q -- "--- Workspace ---" "$KEPT/meta/prompt.txt"'
[ -n "$KEPT" ] && rm -rf "$KEPT"

# --- P*: the OS confinement ------------------------------------------------------
mkdir -p "$ROOT/projects/secret" "$ROOT/refdata"
printf 'TOPSECRET\n' > "$ROOT/projects/secret/secret.txt"
printf 'REFOK\n' > "$ROOT/refdata/ok.txt"
printf 'ORIGINAL\n' > "$OUTSIDE/target.txt"
TMPPROBE="/private/tmp/ext-run-probe.$$.$(date +%s)"
SHARED_PROBE="/Users/Shared/.ext-run-probe.$$"
AGY_BOUNDARY_CLEARED=1 AGY_STAGE_KEEP=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=probe \
  CODEX_STUB_TMPPROBE="$TMPPROBE" CODEX_STUB_ALLOWED="$ROOT/refdata" CODEX_STUB_OUTSIDE="$OUTSIDE" CODEX_STUB_RUNTAG="$$" \
  run_ext read --prompt-file "$BRIEF" --allow-read "$ROOT/refdata"
KEPT=$(kept_stage)
# shellcheck disable=SC2034  # PROBE and PROF are read inside chk's eval'd condition strings
PROBE="$KEPT/ws/probe.txt"
# The generated profile, checked as text on every platform.
# shellcheck disable=SC2034
PROF="$KEPT/meta/sandbox.sb"
# shellcheck disable=SC2034  # XCRUN_T is read inside chk's eval'd condition strings
XCRUN_T=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) && XCRUN_T=$(cd "$XCRUN_T" 2>/dev/null && pwd -P) || XCRUN_T=""
chk "P1 the probe run succeeded and left its results in the workspace" \
  '[ "$RC" -eq 0 ] && [ -n "$KEPT" ] && [ -s "$PROBE" ]'
chk "P6 the profile denies every read under \$HOME and the temp dirs (/private/tmp, /private/var/folders, /tmp, /var/folders) and re-allows \$HOME only as a literal (never its subtree)" \
  'grep -qxF "(deny file-read* (subpath \"$ROOT\") (subpath \"/private/tmp\") (subpath \"/private/var/folders\") (subpath \"/tmp\") (subpath \"/var/folders\"))" "$PROF" && grep -F "(allow file-read* " "$PROF" | grep -qF "(literal \"$ROOT\")" && ! grep -F "(allow file-" "$PROF" | grep -qF "(subpath \"$ROOT\")"'
chk "P6b the profile allows reads of ~/.codex, the workspace, the scratch dir and the --allow-read path" \
  'grep -F "(allow file-read* " "$PROF" | grep -F "(subpath \"$ROOT/.codex\")" | grep -F "(subpath \"$KEPT/ws\")" | grep -F "(subpath \"$KEPT/cx\")" | grep -qF "(subpath \"$ROOT/refdata\")"'
chk "P6c writes are DENY-BY-DEFAULT: (deny file-write* (subpath \"/\")), then only ~/.codex, the workspace, the scratch dir and the documented /dev files — no other write rule" \
  'grep -qxF "(deny file-write* (subpath \"/\"))" "$PROF" && grep -qxF "(allow file-write* (subpath \"$ROOT/.codex\") (subpath \"$KEPT/ws\") (subpath \"$KEPT/cx\"))" "$PROF" && grep -qxF "(allow file-write* (literal \"/dev/null\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/fd/[0-9]+\$\") (literal \"/dev/ptmx\"))" "$PROF" && grep -qxF "(allow file-write* (require-all (regex #\"^/dev/ttys[0-9]+\$\") (extension \"com.apple.sandbox.pty\")))" "$PROF" && [ "$(grep -c "file-write" "$PROF")" -eq 4 ]'
chk "P6d ancestors of the readable paths get METADATA only, as literals (the stage root is stat-able, never listable or readable; meta never)" \
  '[ "$(grep -c "^(allow file-read-metadata " "$PROF")" -eq 1 ] && grep "^(allow file-read-metadata " "$PROF" | grep -F "(literal \"$KEPT\")" | grep -qF "(literal \"$ROOT\")" && ! grep "^(allow file-read-metadata " "$PROF" | grep -qF "(subpath" && ! grep "^(allow file-read\* " "$PROF" | grep -qF "\"$KEPT\")" && ! grep -qF "$KEPT/meta" "$PROF"'
chk "P6e xcrun's tool-path cache in the per-user temp dir is readable as one literal (macOS), never writable" \
  'if [ -n "$XCRUN_T" ]; then grep -qxF "(allow file-read* (literal \"$XCRUN_T/xcrun_db\"))" "$PROF"; else ! grep -q xcrun_db "$PROF"; fi && ! grep "file-write" "$PROF" | grep -q xcrun'
if [ "$REAL_SANDBOX" -eq 1 ]; then
  chk "P2 inside the sandbox the workspace is readable and writable" 'grep -qx "ws-rw=ok" "$PROBE"'
  chk "P3 a file under \$HOME/projects is NOT readable (and its content never reached the workspace)" \
    'grep -qx "home-read=denied" "$PROBE" && ! grep -q TOPSECRET "$PROBE"'
  chk "P4 \$HOME itself is NOT writable (no \$HOME/x)" 'grep -qx "home-write=denied" "$PROBE" && [ ! -e "$ROOT/x" ]'
  chk "P5 /private/tmp is NOT writable" 'grep -qx "tmp-write=denied" "$PROBE" && [ ! -e "$TMPPROBE" ]'
  chk "P5b an --allow-read dir under \$HOME IS readable" 'grep -qx "allowed-read=ok:REFOK" "$PROBE"'
  chk "P5c this script's private meta dir is NOT writable (no rewriting the event stream / audit trail)" \
    'grep -qx "meta-write=denied" "$PROBE" && [ ! -e "$KEPT/meta/tamper.txt" ]'
  chk "P5d codex's private TMPDIR is writable" 'grep -qx "tmpdir-write=ok" "$PROBE"'
  chk "P5e OUTSIDE \$HOME and the temp dirs (/private/var/tmp): no file, dir, symlink or rename-out lands" \
    'grep -qx "outside-write=denied" "$PROBE" && grep -qx "outside-mkdir=denied" "$PROBE" && grep -qx "outside-symlink=denied" "$PROBE" && grep -qx "outside-rename=denied" "$PROBE" && [ "$(ls -A "$OUTSIDE")" = target.txt ]'
  chk "P5f a hard link of an outside file into the workspace cannot be written through (the outside file is unchanged)" \
    'grep -qx "hardlink-write=denied" "$PROBE" && [ "$(cat "$OUTSIDE/target.txt")" = ORIGINAL ]'
  chk "P5g /Users/Shared is NOT writable" \
    'if [ -d /Users/Shared ]; then grep -qx "shared-write=denied" "$PROBE" && [ ! -e "$SHARED_PROBE" ]; else true; fi'
  chk "P5h an --allow-read dir is read-only" 'grep -qx "allowed-write=denied" "$PROBE" && [ ! -e "$ROOT/refdata/w.txt" ]'
  chk "P5i /dev/null and /dev/fd/N (/dev/stderr) stay writable" \
    'grep -qx "devnull-write=ok" "$PROBE" && grep -qx "devfd-write=ok" "$PROBE"'
else
  for n in P2 P3 P4 P5 P5b P5c P5d P5e P5f P5g P5h P5i; do skip "$n real sandbox enforcement" "no sandbox-exec on $(uname -s)"; done
fi
rm -f "$TMPPROBE" "$SHARED_PROBE"
[ -n "$KEPT" ] && rm -rf "$KEPT"

# Build mode with the caller's repo OUTSIDE $HOME and the temp dirs: the
# profile's repo rule is the only thing between codex and the real repo and its
# git dir.
HB="$ROOT/hb"; mkdir -p "$HB/.codex"
HB_BIN=$(stub_home "$HB")
PB="$OUTSIDE/pb"; mkdir -p "$PB"
new_repo "$PB/xrepo"
AGY_BOUNDARY_CLEARED=1 HOME="$HB" CODEX_BIN="$HB_BIN" CODEX_STUB_LOG="$HB/.codex/stub.log" CODEX_STUB_PROMPT="$HB/.codex/stub-prompt.txt" \
  CODEX_STUB_MODE=probebuild CODEX_STUB_REPO="$PB/xrepo" TRIAGE_TIERS="$FIX" \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$PB/xrepo" --patch-out "$PB/probe.patch"
if [ "$REAL_SANDBOX" -eq 1 ]; then
  chk "P7 build mode: the real repo (outside \$HOME and the temp dirs) and its git dir are NOT readable from the sandbox" \
    '[ "$RC" -eq 0 ] && grep -qx "+repo-read=denied" "$PB/probe.patch" && grep -qx "+gitdir-read=denied" "$PB/probe.patch"'
  chk "P7b build mode: the hidden .git pointer cannot be rewritten by codex" \
    'grep -qx "+hidden-git-write=denied" "$PB/probe.patch" && [ "$(wt_count "$PB/xrepo")" -eq 1 ]'
else
  skip "P7 build-mode repo rule" "no sandbox-exec on $(uname -s)"
  skip "P7b hidden .git pointer" "no sandbox-exec on $(uname -s)"
fi
cat "$HB/.codex/stub.log" >> "$ALL_STUB_LOG" 2>/dev/null

# Fail closed. MIRRORS holds PATH dirs re-created without one command.
MIRRORS="$HARNESS/mirrors"
path_without() { # $1 = command name -> PATH with every dir holding it replaced by a mirror lacking it
  local out="" d m f
  local IFS=:
  for d in $PATH; do
    if [ -n "$d" ] && [ -e "$d/$1" ]; then
      m="$MIRRORS/$(printf '%s' "$d" | tr '/' '_')"
      if [ ! -d "$m" ]; then
        mkdir -p "$m"
        for f in "$d"/*; do
          [ "$(basename "$f")" = "$1" ] || ln -s "$f" "$m/$(basename "$f")"
        done
      fi
      d="$m"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
NO_SBX_PATH=$(path_without sandbox-exec)
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok PATH="$NO_SBX_PATH" run_ext read --prompt-file "$BRIEF"
chk "P8 no sandbox-exec: exit 4 (UNAVAILABLE, names sandbox-exec) and codex never ran" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "sandbox-exec not found" && [ ! -s "$STUB_LOG" ]'

# landed_canaries — the paths a failed preflight names as landed (from $ERR).
landed_canaries() { printf '%s' "$ERR" | sed -n 's/.*must deny landed: \([^)]*\)).*/\1/p' | head -1; }
# is_outside_canary PATH — the preflight's second canary: /Users/Shared,
# /private/var/tmp or /var/tmp, named after the run, never under $HOME or a temp dir.
is_outside_canary() {
  case "$1" in
    /Users/Shared/.ext-run-canary-ext-run.*|/private/var/tmp/.ext-run-canary-ext-run.*|/var/tmp/.ext-run-canary-ext-run.*) true ;;
    *) false ;;
  esac
}

PASS_DIR="$HARNESS/passthrough-sbx"; mkdir -p "$PASS_DIR"
printf '#!/bin/sh\nshift 2\nexec "$@"\n' > "$PASS_DIR/sandbox-exec"; chmod +x "$PASS_DIR/sandbox-exec"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok PATH="$PASS_DIR:$PATH" run_ext read --prompt-file "$BRIEF"
LANDED=$(landed_canaries)
# shellcheck disable=SC2034  # L1/L2 are read inside chk's eval'd condition strings
{ L1=${LANDED%% *}; L2=${LANDED#* }; }
chk "P9 a sandbox-exec that runs the command WITHOUT enforcing (the canary writes land): exit 4, codex never ran" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "did not enforce" && [ ! -s "$STUB_LOG" ]'
chk "P9b ...it names BOTH canaries (the stage root's and the one outside \$HOME and the temp dirs) and removed both" \
  'case "$L1" in */ext-run.*/.sandbox-canary) true ;; *) false ;; esac && is_outside_canary "$L2" && [ ! -e "$L1" ] && [ ! -e "$L2" ]'

BADSBX_DIR="$HARNESS/bad-sbx"; mkdir -p "$BADSBX_DIR"
printf '#!/bin/sh\necho "sandbox-exec: syntax error" >&2\nexit 65\n' > "$BADSBX_DIR/sandbox-exec"; chmod +x "$BADSBX_DIR/sandbox-exec"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok PATH="$BADSBX_DIR:$PATH" run_ext read --prompt-file "$BRIEF"
chk "P10 a profile that does not apply (sandbox-exec exits 65): exit 4, codex never ran" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "did not apply" && [ ! -s "$STUB_LOG" ]'

# P12: a sandbox that confines $HOME, the temp dirs and the stage but lets writes
# elsewhere through (the pre-deny-by-default profile) passes a stage-only canary;
# the second canary, outside all of those, must catch it. Portable double: it
# enforces nothing but forges the stage canary's denial.
ONESBX_DIR="$HARNESS/stage-only-sbx"; mkdir -p "$ONESBX_DIR"
cat > "$ONESBX_DIR/sandbox-exec" <<'ONESBX'
#!/bin/sh
[ "$1" = -f ] && [ -s "$2" ] || { echo "stage-only sandbox-exec: expected -f PROFILE" >&2; exit 64; }
shift 2
for a in "$@"; do
  shift
  case "$a" in */.sandbox-canary) set -- "$@" /dev/null ;; *) set -- "$@" "$a" ;; esac
done
exec "$@"
ONESBX
chmod +x "$ONESBX_DIR/sandbox-exec"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok PATH="$ONESBX_DIR:$PATH" run_ext read --prompt-file "$BRIEF"
LANDED=$(landed_canaries)
chk "P12 a sandbox that stops the stage canary but not a write outside \$HOME and the temp dirs: exit 4, only the OUTSIDE canary landed, codex never ran" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "did not enforce" && is_outside_canary "$LANDED" && [ ! -s "$STUB_LOG" ]'
chk "P12a ...and the landed outside canary was removed" '[ -n "$LANDED" ] && [ ! -e "$LANDED" ]'

if [ "$REAL_SANDBOX" -eq 1 ]; then
  # The REAL sandbox-exec, on the generated profile with its write rule rolled
  # back to the pre-2026-09-24 one (writes denied only under $HOME — which holds
  # the stage here — and the temp dirs; allowed everywhere else).
  OLDSBX_DIR="$HARNESS/old-profile-sbx"; mkdir -p "$OLDSBX_DIR"
  cat > "$OLDSBX_DIR/sandbox-exec.in" <<'OLDSBX'
#!/bin/sh
p="$2"; shift 2
sed 's|^(deny file-write\* (subpath "/"))$|(deny file-write* (subpath "@ROOT@") (subpath "/private/tmp") (subpath "/private/var/folders"))|' "$p" > "$p.old"
cmp -s "$p" "$p.old" && { echo "old-profile sandbox-exec: no deny-by-default write rule to roll back" >&2; exit 99; }
exec "@REAL_SBX@" -f "$p.old" "$@"
OLDSBX
  sed -e "s|@ROOT@|$ROOT|g" -e "s|@REAL_SBX@|$(type -P sandbox-exec)|g" "$OLDSBX_DIR/sandbox-exec.in" > "$OLDSBX_DIR/sandbox-exec"
  chmod +x "$OLDSBX_DIR/sandbox-exec"
  AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok PATH="$OLDSBX_DIR:$PATH" run_ext read --prompt-file "$BRIEF"
  LANDED=$(landed_canaries)
  chk "P12b the real sandbox on the old allow-by-default write rule passes the stage canary and is caught by the outside one: exit 4, codex never ran, canary removed" \
    '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "did not enforce" && is_outside_canary "$LANDED" && [ ! -e "$LANDED" ] && [ ! -s "$STUB_LOG" ]'
else
  skip "P12b the real sandbox on the old write rule" "no sandbox-exec on $(uname -s)"
fi

# P13: reads in the temp dirs, as in a parallel compare — the stage under a real
# /private/tmp fixture, $HOME elsewhere; a sibling ext-run stage, a sibling
# candidate's patch and a Claude-scratchpad-like dir under the same parent; a file
# in the per-user temp dir (/private/var/folders); an --allow-read dir inside the
# fixture. P14: what a login zsh, git, python3 and a PTY need inside the sandbox.
HT="$ROOT/ht"
HT_BIN=$(stub_home "$HT")
cp "$BRIEF" "$HT/brief.txt"; cp "$DATA" "$HT/note.txt"
mkdir -p "$TP/ext-run.sibling/ws" "$TP/claude-501/-Users-x-proj/0000-sess/scratchpad" "$TP/refdata"
printf 'SIBSECRET\n' > "$TP/ext-run.sibling/ws/secret.txt"
printf 'PATCHSECRET\n' > "$TP/cand-b.patch"
printf 'SCRATCHSECRET\n' > "$TP/claude-501/-Users-x-proj/0000-sess/scratchpad/secret.txt"
printf 'REFTMP\n' > "$TP/refdata/ok.txt"
VF_FILE=""
VFD=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || VFD=""
if [ -n "$VFD" ] && [ -d "$VFD" ] && VF=$(mktemp -d "${VFD%/}/ext-run-test.XXXXXX"); then
  ALL_TMP="$ALL_TMP $VF"
  printf 'VFSECRET\n' > "$VF/secret.txt"
  VF_FILE="$VF/secret.txt"
fi
PY_OK=""; python3 -c 'import os' >/dev/null 2>&1 && PY_OK=1
AGY_BOUNDARY_CLEARED=1 AGY_STAGE_KEEP=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=probetmp HOME="$HT" TMPDIR="$TP" CODEX_BIN="$HT_BIN" \
  CODEX_STUB_LOG="$HT/.codex/stub.log" CODEX_STUB_PROMPT="$HT/.codex/stub-prompt.txt" \
  CODEX_STUB_SIBLING="$TP/ext-run.sibling/ws/secret.txt" CODEX_STUB_SIBPATCH="$TP/cand-b.patch" \
  CODEX_STUB_SCRATCH="$TP/claude-501/-Users-x-proj/0000-sess/scratchpad/secret.txt" \
  CODEX_STUB_VF="${VF_FILE:-$HARNESS/no-per-user-temp-dir}" CODEX_STUB_ALLOWED="$TP/refdata" CODEX_STUB_PY="$PY_OK" \
  run_ext read --prompt-file "$HT/brief.txt" --input "$HT/note.txt" --allow-read "$TP/refdata"
KEPT=$(kept_stage)
# shellcheck disable=SC2034  # read inside chk's eval'd condition strings
PROBE="$KEPT/ws/probe.txt"
chk "P13 the temp-dir probe ran with its stage under the /private/tmp fixture" \
  '[ "$RC" -eq 0 ] && case "$KEPT" in "$TP"/ext-run.*) true ;; *) false ;; esac && [ -s "$PROBE" ]'
if [ "$REAL_SANDBOX" -eq 1 ]; then
  chk "P13a its own workspace and an --allow-read dir INSIDE the temp dirs stay readable" \
    'grep -qx "ws-read=ok:needle" "$PROBE" && grep -qx "allowed-read=ok:REFTMP" "$PROBE"'
  chk "P13b a sibling stage and a sibling candidate patch under the same parent are NOT readable, nor is the parent listable" \
    'grep -qx "sibling-read=denied" "$PROBE" && grep -qx "sibpatch-read=denied" "$PROBE" && grep -qx "stage-parent-list=denied" "$PROBE" && ! grep -q "SECRET" "$PROBE"'
  chk "P13c a Claude-scratchpad-like dir under /private/tmp is NOT readable" 'grep -qx "scratch-read=denied" "$PROBE"'
  chk "P13d a file in the per-user temp dir (/private/var/folders) is NOT readable" \
    'if [ -n "$VF_FILE" ]; then grep -qx "varfolders-read=denied" "$PROBE"; else true; fi'
  chk "P13e the stage's own meta dir (the prompt) is NOT readable" 'grep -qx "meta-read=denied" "$PROBE"'
  chk "P14 git works in the workspace: init, rev-parse --show-toplevel (realpath through the stat-only temp-dir ancestors), commit" \
    'grep -qx "git=ok" "$PROBE"'
  chk "P14b a login zsh (zsh -lc) runs" 'grep -qx "zsh-login=ok" "$PROBE"'
  chk "P14c python3 runs (tempfile in TMPDIR, realpath of the workspace)" \
    'if [ -n "$PY_OK" ]; then grep -qx "python=ok" "$PROBE"; else true; fi'
  chk "P14d a PTY can be allocated (/dev/ptmx + a sandbox-created /dev/ttysN)" 'grep -qx "pty=ok" "$PROBE"'
  chk "P14e opening /dev/tty is not refused by the sandbox (no controlling terminal => ENXIO, as unsandboxed)" 'grep -qx "tty-open=ok" "$PROBE"'
else
  for n in P13a P13b P13c P13d P13e P14 P14b P14c P14d P14e; do skip "$n real sandbox enforcement" "no sandbox-exec on $(uname -s)"; done
fi
cat "$HT/.codex/stub.log" >> "$ALL_STUB_LOG" 2>/dev/null
[ -n "$KEPT" ] && rm -rf "$KEPT"

# --- A*: --allow-read ------------------------------------------------------------
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --allow-read "$DENY/clip-creator/inner"
chk "A1 --allow-read of a deny-listed repo is REFUSED (exit 3), codex never runs" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --allow-read "$ROOT"
chk "A2 --allow-read \$HOME is REFUSED (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "re-open all of" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --allow-read "$(dirname "$ROOT")"
chk "A3 --allow-read of an ancestor of \$HOME is REFUSED (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "ancestor of" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --allow-read "$DENY"
chk "A4 --allow-read of a dir with a deny-listed repo beneath it is REFUSED (exit 3, names it)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "contains .*clip-creator" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --allow-read "$MARKED"
chk "A5 --allow-read of a dir with a .codex-deny marker beneath it is REFUSED (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "contains .*\.codex-deny" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --allow-read "$ROOT/no-such-dir"
chk "A6 a missing --allow-read path is a usage error (exit 2)" '[ "$RC" -eq 2 ] && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --allow-read "$ROOT/refdata"
chk "A7 an allowed --allow-read path is named in the prompt footer" \
  '[ "$RC" -eq 0 ] && grep -q "^Also readable (read-only):" "$STUB_PROMPT" && grep -qx "  $ROOT/refdata" "$STUB_PROMPT"'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --allow-read
chk "A8 a trailing --allow-read with no value is exit 2" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q -- "--allow-read needs a value"'

# --- L*: the command audit log --------------------------------------------------
AUD="$ROOT/audit/a.jsonl"
AGY_BOUNDARY_CLEARED=1 AGY_STAGE_KEEP=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=cmds EXT_RUN_AUDIT_LOG="$AUD" \
  run_ext review --prompt-file "$BRIEF"
KEPT=$(kept_stage)
chk "L1 one audit line per command_execution item (started+completed collapse to one), run passes" \
  '[ "$RC" -eq 0 ] && [ "$(wc -l < "$AUD" | tr -d " ")" -eq 2 ]'
chk "L1b each line has exactly {ts, runId, mode, model, cwd, command, exitCode}" \
  '[ "$(jq -c "keys" "$AUD" | sort -u)" = "[\"command\",\"cwd\",\"exitCode\",\"mode\",\"model\",\"runId\",\"ts\"]" ]'
chk "L1c command + exitCode recorded (0 and 2), mode/model/runId/cwd from this run" \
  '[ "$(jq -r ".exitCode" "$AUD" | tr "\n" ,)" = "0,2," ] && [ "$(head -1 "$AUD" | jq -r .command)" = "bash -lc ls" ] && [ "$(jq -r "[.mode,.model] | join(\"/\")" "$AUD" | sort -u)" = "review/gpt-fx-review" ] && [ "$(jq -r .runId "$AUD" | sort -u)" = "$(basename "$KEPT")" ] && [ "$(jq -r .cwd "$AUD" | sort -u)" = "$KEPT/ws" ]'
chk "L1d a long command is truncated to 500 chars" '[ "$(sed -n 2p "$AUD" | jq -r ".command | length")" -eq 500 ]'
chk "L1e NEVER the command output: no aggregated_output key, no output text" \
  '! grep -q "aggregated_output" "$AUD" && ! grep -q "SECRET-OUTPUT" "$AUD"'
[ -n "$KEPT" ] && rm -rf "$KEPT"

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=cmds run_ext review --prompt-file "$BRIEF"
chk "L2 the default audit log is \$HOME/.claude/logs/ext-run/codex-commands.jsonl" \
  '[ "$RC" -eq 0 ] && [ "$(wc -l < "$ROOT/.claude/logs/ext-run/codex-commands.jsonl" | tr -d " ")" -eq 2 ]'

AUD3="$ROOT/audit/failed.jsonl"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=cmdsfail EXT_RUN_AUDIT_LOG="$AUD3" run_ext review --prompt-file "$BRIEF"
chk "L3 a run that fails its gates (exit 4) is still audited" \
  '[ "$RC" -eq 4 ] && [ "$(wc -l < "$AUD3" | tr -d " ")" -eq 2 ]'

AUD4="$ROOT/audit/prune.jsonl"
printf '%s\n' '{"ts":"2000-01-01T00:00:00Z","runId":"old","mode":"read","model":"m","cwd":"/x","command":"old","exitCode":0}' \
  '{"ts":"2099-01-01T00:00:00Z","runId":"future","mode":"read","model":"m","cwd":"/x","command":"kept","exitCode":0}' > "$AUD4"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=cmds EXT_RUN_AUDIT_LOG="$AUD4" run_ext review --prompt-file "$BRIEF"
chk "L4 lines older than 30 days are pruned; recent ones kept; the new ones appended" \
  '[ "$RC" -eq 0 ] && ! grep -q "\"runId\":\"old\"" "$AUD4" && grep -q "\"runId\":\"future\"" "$AUD4" && [ "$(wc -l < "$AUD4" | tr -d " ")" -eq 3 ]'

RO="$ROOT/ro-audit"; mkdir -p "$RO"; chmod 500 "$RO"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=cmds EXT_RUN_AUDIT_LOG="$RO/sub/a.jsonl" run_ext review --prompt-file "$BRIEF"
chmod 700 "$RO"
chk "L5 an audit log dir that cannot be created is UNAVAILABLE (exit 4) and codex never ran" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "audit log" && [ ! -s "$STUB_LOG" ]'

# --- C2-C9: the flag table per mode, gates, watchdog -------------------------------
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext verify --prompt-file "$BRIEF"
chk "C2 verify adds -c web_search=\"live\" on the fixture verify model/effort" \
  '[ "$RC" -eq 0 ] && grep -qx "CFG=web_search=\"live\"" "$STUB_LOG" && grep -qx "MODEL=gpt-fx-verify" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=medium" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext review --vendor codex --prompt-file "$BRIEF" --effort xhigh
chk "C3 review uses the fixture review model; --effort overrides the tiers effort (--vendor codex accepted)" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gpt-fx-review" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=xhigh" "$STUB_LOG" && ! grep -q "CFG=model_reasoning_effort=high" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext review --prompt-file "$BRIEF" --effort max
chk "C3a codex accepts --effort max and passes it through unchanged" \
  '[ "$RC" -eq 0 ] && grep -qx "CFG=model_reasoning_effort=max" "$STUB_LOG"'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext review --prompt-file "$BRIEF" --effort ultra
chk "C3a2 codex refuses --effort ultra (auto-delegating mode) as a usage error" '[ "$RC" -eq 2 ] && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext review --prompt-file "$BRIEF" --effort ludicrous
chk "C3b an invalid codex --effort is a usage error (exit 2)" '[ "$RC" -eq 2 ] && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext critique --prompt-file "$BRIEF"
chk "C3c a codex tiers entry with no effort (and no --effort) is a usage error, never a default" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "no effort" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF"
chk "C4 without TRIAGE_TIERS the repo seed is used (codex read -> gpt-6-sol, low)" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gpt-6-sol" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=low" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=empty run_ext read --prompt-file "$BRIEF"
chk "C5a an empty -o final message with rc 0 is UNAVAILABLE (exit 4), not a pass" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "no final message" && [ -z "$OUT" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=failed run_ext read --prompt-file "$BRIEF"
chk "C5b turn.failed + error event, rc 1, no -o file is UNAVAILABLE (exit 4) with the reason" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "exited 1" && printf "%s" "$ERR" | grep -q "stream disconnected"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=failedrc0 run_ext read --prompt-file "$BRIEF"
chk "C5c a failure event is UNAVAILABLE even with rc 0 and a non-empty -o file" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "turn.failed event"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=exit7 run_ext read --prompt-file "$BRIEF"
chk "C5d a non-zero codex exit is UNAVAILABLE (exit 4) even with a final message" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "exited 7"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=schemaok run_ext read --prompt-file "$BRIEF" --schema '{"type":"object"}'
chk "C5e --schema: a JSON final message exits 0; the inline schema reaches codex as --output-schema FILE" \
  '[ "$RC" -eq 0 ] && [ "$(printf "%s" "$OUT" | jq -r .verdict)" = "clean" ] && grep -qx "OSCHEMA={\"type\":\"object\"}" "$STUB_LOG"'

mkdir -p "$ROOT/schemas"; printf '{"type":"object","title":"from-home"}' > "$ROOT/schemas/s.json"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=schemaok run_ext read --prompt-file "$BRIEF" --schema "$ROOT/schemas/s.json"
chk "C5e2 a --schema FILE under \$HOME is copied where the sandboxed codex can read it" \
  '[ "$RC" -eq 0 ] && grep -qx "OSCHEMA={\"type\":\"object\",\"title\":\"from-home\"}" "$STUB_LOG" && ! grep -q "^ARG=$ROOT/schemas/s.json$" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=schemabad run_ext read --prompt-file "$BRIEF" --schema '{"type":"object"}'
chk "C5f --schema with a non-JSON final message is exit 5 (SCHEMA)" '[ "$RC" -eq 5 ]'

T_START=$SECONDS
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=hang run_ext read --prompt-file "$BRIEF" --timeout 1s
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
T_TOOK=$((SECONDS - T_START))
chk "C5g the wall-clock watchdog kills a hung codex: exit 4, says timed out, well before the hang ends" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "timed out after 1s" && [ "$T_TOOK" -lt 15 ]'

# K*: the whole process tree dies with the run — a grandchild that ignores TERM
# (the watchdog's TERM kills the parent, which stops the watchdog before its KILL)
# and a background grandchild of a run that exited normally.
export CODEX_STUB_GC="$ROOT/.codex/codex-gc.pid"
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
rm -f "$CODEX_STUB_GC"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=hanggc run_ext read --prompt-file "$BRIEF" --timeout 1s
GC1=$(cat "$CODEX_STUB_GC" 2>/dev/null)
chk "K1 a timed-out codex's TERM-ignoring grandchild is killed and reaped before ext-run exits (exit 4, timed out)" \
  '[ "$RC" -eq 4 ] && printf "%s" "$ERR" | grep -q "timed out" && [ -n "$GC1" ] && ! alive "$GC1"'
alive "$GC1" && kill -9 "$GC1" 2>/dev/null
rm -f "$CODEX_STUB_GC"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=okgc run_ext read --prompt-file "$BRIEF"
GC2=$(cat "$CODEX_STUB_GC" 2>/dev/null)
chk "K2 a background grandchild left by a codex run that exited normally is killed too (exit 0, answer intact)" \
  '[ "$RC" -eq 0 ] && [ "$OUT" = "hello from codex" ] && [ -n "$GC2" ] && ! alive "$GC2"'
alive "$GC2" && kill -9 "$GC2" 2>/dev/null

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --timeout 1m30s
chk "C5h a --timeout the watchdog cannot parse is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --raw
chk "C5i --raw relays the codex JSONL event stream" \
  '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "\"type\":\"turn.completed\""'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_BIN="$HARNESS/no-such-codex" run_ext read --prompt-file "$BRIEF"
chk "C5j a missing codex binary is UNAVAILABLE (exit 4)" '[ "$RC" -eq 4 ] && [ ! -s "$STUB_LOG" ]'

# --- B*: build mode — the disposable worktree ----------------------------------
BUILD=$(new_tmp)
REPO="$BUILD/repo"
new_repo "$REPO"
printf 'DIRTY\n' > "$REPO/dirty.txt"                 # uncommitted, untracked
printf 'line1\nline2\nCHANGED\n' > "$REPO/calc.txt"  # uncommitted, tracked
mkdir -p "$REPO/sub"
printf 'deep untracked\n' > "$REPO/sub/deep.txt"
git -C "$REPO" add dirty.txt >/dev/null 2>&1          # staged-but-uncommitted
printf 'new untracked\n' > "$REPO/new.txt"
PATCH="$BUILD/result.patch"

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$REPO" --output "$PATCH" --input "$DATA"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_PWD=$(grep '^PWD=' "$STUB_LOG" | head -1 | sed 's/^PWD=//')
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STUB_TOP=$(grep '^GITTOP=' "$STUB_LOG" | head -1 | sed 's/^GITTOP=//')

chk "B1 build runs in a disposable worktree, NOT in the caller's repo; -C = that worktree" \
  '[ -n "$STUB_PWD" ] && [ "$STUB_PWD" != "$REPO" ] && case "$STUB_PWD" in */ext-run.*/build) true ;; *) false ;; esac && [ "$(grep "^CDIR=" "$STUB_LOG" | sed "s/^CDIR=//")" = "$STUB_PWD" ]'
chk "B1a codex sees NO .git in its cwd and git finds no repo there (the worktree's .git names the real gitdir)" \
  'grep -qx "DOTGIT=absent" "$STUB_LOG" && [ -z "$STUB_TOP" ]'
chk "B1b build: level model/effort, confined like every run" \
  'grep -qx "MODEL=gpt-fx-builder" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=medium" "$STUB_LOG" && grep -qx "SANDBOXED=$EXPECT_SBX" "$STUB_LOG"'
chk "B2 the caller's uncommitted tracked change is carried into the stage" \
  'grep -qx "SEEN calc.txt=line1" "$STUB_LOG" && [ "$(grep -c "^SEEN calc.txt=" "$STUB_LOG")" -eq 1 ]'
chk "B2b the caller's untracked files are carried in (top level and nested)" \
  'grep -qx "SEEN new.txt=new untracked" "$STUB_LOG" && grep -qx "SEEN sub/deep.txt=deep untracked" "$STUB_LOG"'
chk "B2c a staged-but-uncommitted file is carried in too" \
  'grep -qx "SEEN dirty.txt=DIRTY" "$STUB_LOG"'
chk "B2d --input is staged inside the worktree as .codex-inputs/<name>" \
  'grep -qx "SEEN .codex-inputs/note.txt=needle" "$STUB_LOG"'
chk "B3 the result patch is written to --output and is non-empty" \
  '[ "$RC" -eq 0 ] && [ -s "$PATCH" ]'
chk "B3b the patch is applied back to the real repo (edit + new file land)" \
  'tail -1 "$REPO/calc.txt" | grep -qx "CODEX WAS HERE" && [ -f "$REPO/gen.txt" ]'
chk "B3c the patch is the PURE codex delta — the carried work is not re-applied" \
  '[ "$(grep -c "^CHANGED$" "$REPO/calc.txt")" -eq 1 ] && ! grep -q "dirty.txt" "$PATCH"'
chk "B3d staged --input files never leak into the caller's repo" \
  '[ ! -e "$REPO/.codex-inputs" ]'
chk "B3e the caller's own uncommitted work survives the apply untouched" \
  '[ "$(cat "$REPO/dirty.txt")" = "DIRTY" ] && [ "$(cat "$REPO/new.txt")" = "new untracked" ]'
chk "B4 stdout is the model answer and the apply is reported on stderr" \
  'printf "%s" "$OUT" | grep -q "DONE exit=0" && printf "%s" "$ERR" | grep -q "applied the build patch"'
chk "B5 the worktree is removed on exit — the caller's repo has one worktree again" \
  '[ "$(wt_count "$REPO")" -eq 1 ] && [ ! -e "$STUB_PWD" ]'

# B6: codex makes no change at all.
REPO2="$BUILD/repo2"
new_repo "$REPO2"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
BEFORE2=$(git -C "$REPO2" status --porcelain)
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildnoop \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$REPO2" --output "$BUILD/noop.patch"
chk "B6 a build that changes nothing exits 0, says so, and leaves the tree alone" \
  '[ "$RC" -eq 0 ] && printf "%s" "$ERR" | grep -q "NO changes" && [ "$(git -C "$REPO2" status --porcelain)" = "$BEFORE2" ]'

# B7: the run fails its gates — the real tree must not be touched.
REPO3="$BUILD/repo3"
new_repo "$REPO3"
printf 'untouched\n' > "$REPO3/dirty.txt"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
BEFORE3=$(git -C "$REPO3" status --porcelain)
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=empty \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$REPO3" --output "$BUILD/empty.patch"
chk "B7 an empty final message in build mode is exit 4 and the real tree is untouched" \
  '[ "$RC" -eq 4 ] && [ "$(git -C "$REPO3" status --porcelain)" = "$BEFORE3" ] && [ "$(cat "$REPO3/dirty.txt")" = "untouched" ]'
chk "B7b the unapplied patch is kept and named on stderr" \
  'printf "%s" "$ERR" | grep -q "NOT applied" && [ -e "$BUILD/empty.patch" ]'
chk "B7c the worktree is removed even when the run failed its gates" \
  '[ "$(wt_count "$REPO3")" -eq 1 ]'

# B8: the patch cannot apply (the caller's tree drifted: --check, which runs
# outside the sandbox between capture and apply, stands in for that drift).
REPO4="$BUILD/repo4"
new_repo "$REPO4"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildconflict \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$REPO4" --output "$BUILD/conflict.patch" \
  --check "printf 'line1\nREAL-DRIFT\nline3\n' > '$REPO4/conflict.txt'"
chk "B8 a patch that does not apply is exit 6 (APPLY), distinct from 4" \
  '[ "$RC" -eq 6 ]'
chk "B8b the failed patch is left for inspection and stderr says APPLY" \
  '[ -s "$BUILD/conflict.patch" ] && printf "%s" "$ERR" | grep -q "^APPLY:"'
chk "B8c the model answer is still relayed on an apply failure" \
  'printf "%s" "$OUT" | grep -q "DONE exit=0"'
chk "B8d the worktree is still removed after an apply failure" \
  '[ "$(wt_count "$REPO4")" -eq 1 ]'

# B9: --workdir must be a git repo, and the default --output path works.
NOTGIT="$BUILD/plain"
mkdir -p "$NOTGIT"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext build --level builder --prompt-file "$BRIEF" --workdir "$NOTGIT"
chk "B9 build against a non-git directory is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "not a git work tree"'

REPO5="$BUILD/repo5"
new_repo "$REPO5"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$REPO5"
DEFAULT_PATCH=$(printf '%s' "$ERR" | sed -n 's/.*applied the build patch to [^ ]* (\(.*\))$/\1/p' | head -1)
chk "B9b --output is optional: the patch goes to a temp file whose path is printed" \
  '[ "$RC" -eq 0 ] && [ -n "$DEFAULT_PATCH" ] && [ -s "$DEFAULT_PATCH" ]'
[ -n "$DEFAULT_PATCH" ] && rm -f "$DEFAULT_PATCH"

# B10: a CLI that creates its OWN .git in the workspace: discarded, the worktree's
# .git restored, the patch still captured and applied.
REPO6="$BUILD/repo6"
new_repo "$REPO6"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildmkgit run_ext build --level builder --prompt-file "$BRIEF" --workdir "$REPO6" --output "$BUILD/mkgit.patch"
chk "B10 a .git the CLI created is discarded; the worktree's own .git is restored and the patch captured + applied" \
  '[ "$RC" -eq 0 ] && grep -q "^+CODEX WAS HERE$" "$BUILD/mkgit.patch" && ! grep -q "\.git/" "$BUILD/mkgit.patch" && tail -1 "$REPO6/calc.txt" | grep -qx "CODEX WAS HERE" && [ "$(wt_count "$REPO6")" -eq 1 ] && [ -z "$(ls -A "$REPO6/.git/worktrees" 2>/dev/null)" ]'

# B11: a conflicting apply NEVER leaves markers: the caller's STAGED drift makes a
# 3-way merge conflict; the pre-check refuses it, exit 6, tree byte-identical.
REPO7="$BUILD/repo7"
new_repo "$REPO7"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildconflict \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$REPO7" --output "$BUILD/conflict7.patch" \
  --check "printf 'line1\nREAL-DRIFT\nline3\n' > '$REPO7/conflict.txt' && git -C '$REPO7' add conflict.txt && { git -C '$REPO7' status --porcelain; cksum < '$REPO7/.git/index'; cksum < '$REPO7/conflict.txt'; } > '$BUILD/repo7.state'"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
STATE7=$({ git -C "$REPO7" status --porcelain; cksum < "$REPO7/.git/index"; cksum < "$REPO7/conflict.txt"; })
chk "B11 a patch whose 3-way merge would conflict is exit 6 and the caller's tree + index are byte-identical (no markers)" \
  '[ "$RC" -eq 6 ] && [ -s "$BUILD/repo7.state" ] && [ "$STATE7" = "$(cat "$BUILD/repo7.state")" ] && ! grep -q "^<<<<<<<" "$REPO7/conflict.txt" && [ "$(sed -n 2p "$REPO7/conflict.txt")" = "REAL-DRIFT" ]'
chk "B11b ...stderr says APPLY, nothing was written, and the patch is kept" \
  'printf "%s" "$ERR" | grep -q "^APPLY:.*nothing was written" && [ -s "$BUILD/conflict7.patch" ]'

# B12: the 3-way fallback still recovers a drift that does not conflict.
REPO8="$BUILD/repo8"
new_repo "$REPO8"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$REPO8/long.txt"
git -C "$REPO8" add long.txt && git -C "$REPO8" commit -qm long
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=build3way \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$REPO8" --output "$BUILD/3way.patch" \
  --check "printf 'l1\nl2\nl3\nDRIFT4\nl5\nl6\nl7\nl8\n' > '$REPO8/long.txt' && git -C '$REPO8' add long.txt"
chk "B12 a non-conflicting drift is applied by the clean 3-way path (both changes land, exit 0)" \
  '[ "$RC" -eq 0 ] && printf "%s" "$ERR" | grep -q "3-way merge" && [ "$(sed -n 1p "$REPO8/long.txt")" = EDIT1 ] && [ "$(sed -n 4p "$REPO8/long.txt")" = DRIFT4 ]'

# D1: an inherited GIT_DIR/GIT_WORK_TREE (a git hook's environment) must not
# redirect ext-run's git calls into another repository.
DREPO="$BUILD/drepo"; DECOY="$BUILD/decoy"
new_repo "$DREPO"; new_repo "$DECOY"
# shellcheck disable=SC2034  # used inside chk's eval'd condition strings, not directly
DECOY_BEFORE=$({ git -C "$DECOY" status --porcelain; git -C "$DECOY" rev-parse HEAD; git -C "$DECOY" worktree list; })
GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" GIT_INDEX_FILE="$DECOY/.git/index" AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$DREPO" --output "$BUILD/d1.patch"
chk "D1 inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE are cleared: the build lands in --workdir, the decoy repo is untouched" \
  '[ "$RC" -eq 0 ] && tail -1 "$DREPO/calc.txt" | grep -qx "CODEX WAS HERE" && [ -f "$DREPO/gen.txt" ] && [ ! -e "$DECOY/gen.txt" ] && [ "$(git -C "$DECOY" status --porcelain; git -C "$DECOY" rev-parse HEAD; git -C "$DECOY" worktree list)" = "$DECOY_BEFORE" ]'

# --- E*: a symlink is judged — and read — at its target -------------------------
SYM=$(new_tmp)
printf '{"type":"object"}\n' > "$DENY/clip-creator/schema.json"
ln -s "$DENY/clip-creator/note.txt" "$SYM/link-note.txt"
ln -s "link-note.txt" "$SYM/link2.txt"
ln -s "$DENY/clip-creator/note.txt" "$SYM/brief-link.txt"
ln -s "$DENY/clip-creator/schema.json" "$SYM/schema-link.json"
ln -s "$DENY/clip-creator/inner" "$SYM/wd-link"
printf 'secret\n' > "$MARKED/repo/secret.txt"
ln -s "$MARKED/repo/secret.txt" "$SYM/marked-link.txt"
ln -s "$DATA" "$SYM/ok-link.txt"
ln -s "$DENY/clip-creator" "$SYM/allow-link"
AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$BRIEF" --input "$SYM/link-note.txt"
chk "E1 an --input symlink in an allowed dir pointing into clip-creator is REFUSED (exit 3), codex never runs" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$BRIEF" --input "$SYM/link2.txt"
chk "E2 a symlink CHAIN (link -> link -> denied file) is followed to the end and refused (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$SYM/brief-link.txt"
chk "E3 a --prompt-file symlink into clip-creator is refused (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$BRIEF" --schema "$SYM/schema-link.json"
chk "E4 a --schema symlink into clip-creator is refused (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 run_ext build --level builder --prompt-file "$BRIEF" --workdir "$SYM/wd-link"
chk "E5 a --workdir symlink to a clip-creator repo is refused (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$BRIEF" --input "$SYM/marked-link.txt"
chk "E6 a symlink into a .codex-deny tree is refused by the marker at its TARGET (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 CODEX_STUB_MODE=ok AGY_STAGE_KEEP=1 run_ext read --prompt-file "$BRIEF" --input "$SYM/ok-link.txt"
KEPT=$(kept_stage)
chk "E7 an allowed symlink runs: staged under the caller's name with the TARGET's content (a copy, not a link)" \
  '[ "$RC" -eq 0 ] && [ -n "$KEPT" ] && [ -f "$KEPT/ws/inputs/ok-link.txt" ] && [ ! -L "$KEPT/ws/inputs/ok-link.txt" ] && [ "$(cat "$KEPT/ws/inputs/ok-link.txt")" = needle ]'
[ -n "$KEPT" ] && rm -rf "$KEPT"
AGY_BOUNDARY_CLEARED=1 run_ext read --prompt-file "$BRIEF" --allow-read "$SYM/allow-link"
chk "E8 an --allow-read symlink into clip-creator is refused at its target (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'

# --- J*: a marker exactly AT $HOME counts; one above $HOME does not ---------------
HM=$(new_tmp)
HMP=$(cd "$HM" && pwd -P)
new_repo "$HMP/proj"
cp "$BRIEF" "$HMP/brief.txt"   # every checked path under this case's HOME (hermetic)
: > "$HMP/.codex-deny"
HOME="$HMP" AGY_BOUNDARY_CLEARED=1 CODEX_STUB_MODE=buildnoop run_ext build --level builder --prompt-file "$HMP/brief.txt" --workdir "$HMP/proj" --output "$HMP/j1.patch"
chk "J1 a .codex-deny marker at \$HOME itself refuses (exit 3) — the walk checks \$HOME before stopping" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "$HMP/.codex-deny" && [ ! -s "$STUB_LOG" ]'
HA=$(new_tmp)
HAP=$(cd "$HA" && pwd -P)
mkdir -p "$HAP/home/.codex"
HAP_BIN=$(stub_home "$HAP/home")
new_repo "$HAP/home/proj"
cp "$BRIEF" "$HAP/home/brief.txt"
: > "$HAP/.codex-deny"
HOME="$HAP/home" CODEX_BIN="$HAP_BIN" CODEX_STUB_LOG="$HAP/home/.codex/stub.log" CODEX_STUB_PROMPT="$HAP/home/.codex/stub-prompt.txt" \
  AGY_BOUNDARY_CLEARED=1 CODEX_STUB_MODE=buildnoop run_ext build --level builder --prompt-file "$HAP/home/brief.txt" --workdir "$HAP/home/proj" --output "$HAP/j2.patch"
chk "J2 a marker ABOVE \$HOME is not consulted (the walk still stops at \$HOME)" '[ "$RC" -eq 0 ]'
cat "$HAP/home/.codex/stub.log" >> "$ALL_STUB_LOG" 2>/dev/null

# --- G*: a trailing value-taking option is a usage error, never a hang ------------
# bounded RC-capturing run: perl's alarm kills a regressed (looping) parser.
# shellcheck disable=SC2034  # OUT is read inside chk's eval'd condition strings
run_bounded() { OUT=$(perl -e 'alarm shift; exec @ARGV' 20 "$EXT_RUN" "$@" 2>"$ERRF"); RC=$?; ERR=$(cat "$ERRF"); }
AGY_BOUNDARY_CLEARED=1 run_bounded review --prompt-file "$BRIEF" --vendor
chk "G1 a trailing --vendor with no value is exit 2 (needs a value), not an endless loop" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q -- "--vendor needs a value"'
AGY_BOUNDARY_CLEARED=1 run_bounded review --prompt-file
chk "G2 a trailing --prompt-file is exit 2 too" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q -- "--prompt-file needs a value"'

# --- T*: tiers.json — the ONLY source of external model ids ----------------------
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$HARNESS/no-such-tiers.json" run_ext read --prompt-file "$BRIEF"
chk "T2 a missing tiers file is a usage error (exit 2) and nothing runs" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "tiers file not found" && [ ! -s "$STUB_LOG" ]'

printf '{"levels": {' > "$HARNESS/bad-tiers.json"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$HARNESS/bad-tiers.json" run_ext read --prompt-file "$BRIEF"
chk "T3 an unparseable tiers file is a usage error (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "not valid tiers JSON" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext fuzz --prompt-file "$BRIEF"
chk "T4 a mode absent for codex in the tiers file is REFUSED (exit 3), never a default model" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "modes.codex.fuzz" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 run_ext review --level deep --prompt-file "$BRIEF"
chk "T7 --level outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

# Lookup order: an installed triage-tiers.json next to the script wins over the
# repo file, and $TRIAGE_TIERS wins over both.
INST=$(new_tmp)
cp "$EXT_RUN" "$INST/ext-run.sh"
jq '.modes.codex.read.model = "gpt-installed"' "$REPO_DIR/config/tiers.json" > "$INST/triage-tiers.json"
REAL_EXT_RUN="$EXT_RUN"
EXT_RUN="$INST/ext-run.sh"
AGY_BOUNDARY_CLEARED=1 CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF"
chk "T10 an installed triage-tiers.json next to the script is used" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gpt-installed" "$STUB_LOG"'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF"
chk "T10b TRIAGE_TIERS overrides the installed copy" \
  'grep -qx "MODEL=gpt-fx-read" "$STUB_LOG"'
EXT_RUN="$REAL_EXT_RUN"

# --- C6: the deny-list; clip-creator is denied whatever the environment says ----
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_DENY_REPOS="something-else" run_ext build --level builder --prompt-file "$BRIEF" --workdir "$DENY/clip-creator/inner"
chk "C6c clip-creator stays hard-denied even when CODEX_DENY_REPOS is overridden" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'

mkdir -p "$DENY/codex-only"
new_repo "$DENY/codex-only/proj"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_DENY_REPOS="codex-only" \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$DENY/codex-only/proj"
chk "C6d a CODEX_DENY_REPOS name refuses codex (exit 3, component match)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "codex-only"'

# --- C6w: a LINKED worktree outside the repo is deny-checked via its main worktree --
# triage-compare stages candidates in linked worktrees under an outDir outside the
# repo, so the worktree's own path never names the repo. ext-run must resolve the
# main worktree (git-common-dir) and deny-check it too. Markers are left UNTRACKED
# in the main repo so the linked checkout does not carry them — only the
# common-dir check can see them.
new_linked_wt() { # $1 = main repo (created), $2 = linked worktree path (outside it)
  new_repo "$1"
  git -C "$1" worktree add -q --detach "$2" HEAD
}
LWD=$(new_tmp); LWO=$(new_tmp)
new_linked_wt "$LWD/clip-creator/proj" "$LWO/wt"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildnoop \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$LWO/wt" --output "$LWO/codex.patch"
chk "C6k a linked worktree outside a clip-creator repo is REFUSED (exit 3, names the main worktree), codex never runs" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && printf "%s" "$ERR" | grep -q "main worktree" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --input "$LWO/wt/calc.txt"
chk "C6m an --input file inside that linked worktree is REFUSED (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'

LAM=$(new_tmp); LAO=$(new_tmp)
new_linked_wt "$LAM/repo" "$LAO/wt"
: > "$LAM/repo/.agy-deny"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildnoop \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$LAO/wt" --output "$LAO/codex.patch"
chk "C6o a leftover .agy-deny in the MAIN repo does not refuse codex (inert)" '[ "$RC" -eq 0 ]'

LCM=$(new_tmp); LCO=$(new_tmp)
new_linked_wt "$LCM/repo" "$LCO/wt"
: > "$LCM/repo/.codex-deny"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildnoop \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$LCO/wt" --output "$LCO/codex.patch"
chk "C6p a .codex-deny marker in the MAIN repo refuses its linked worktree (exit 3, names the marker)" \
  '[ ! -e "$LCO/wt/.codex-deny" ] && [ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --input "$LCO/wt/calc.txt"
chk "C6p2 an --input file in that linked worktree is refused by the main repo's .codex-deny (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny"'

LOM=$(new_tmp); LOO=$(new_tmp)
new_linked_wt "$LOM/repo" "$LOO/wt"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$LOO/wt" --patch-out "$LOO/codex.patch"
chk "C6s a normal linked worktree builds (--patch-out written, the linked worktree left clean, main repo untouched)" \
  '[ "$RC" -eq 0 ] && grep -q "^+CODEX WAS HERE$" "$LOO/codex.patch" && [ -z "$(git -C "$LOO/wt" status --porcelain)" ] && ! grep -q "CODEX WAS HERE" "$LOM/repo/calc.txt"'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input "$LOO/wt/calc.txt"
chk "C6t an --input file from a normal linked worktree is staged and runs (exit 0)" '[ "$RC" -eq 0 ]'

# --- C7-C9: levels, fixture edits, vendor/model mismatch ------------------------
CREPO="$BUILD/crepo"
new_repo "$CREPO"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext build --level quick --prompt-file "$BRIEF" --workdir "$CREPO"
chk "C7 a level missing from the tiers file is REFUSED (exit 3); codex never runs on a default model" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "levels.quick.codex" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext build --prompt-file "$BRIEF" --workdir "$CREPO"
chk "C7b codex build without --level is REFUSED (no modes.codex.build entry)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "modes.codex.build" && [ ! -s "$STUB_LOG" ]'

FIX2="$HARNESS/tiers-fixture2.json"
jq '.levels.deep.codex.model = "gpt-fx-deep-v2" | .levels.deep.codex.effort = "xhigh"' "$FIX" > "$FIX2"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX2" CODEX_STUB_MODE=buildnoop \
  run_ext build --level deep --prompt-file "$BRIEF" --workdir "$CREPO" --output "$BUILD/c8.patch"
chk "C8 a model/effort change in the tiers file is picked up with no code edit" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=gpt-fx-deep-v2" "$STUB_LOG" && grep -qx "CFG=model_reasoning_effort=xhigh" "$STUB_LOG"'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext review --prompt-file "$BRIEF" --model gemini-3.1-pro-high
chk "C9a codex refuses a Gemini model (vendor/model mismatch, exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "does not belong" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext review --prompt-file "$BRIEF" --model gpt-claude-bridge
chk "C9b anything naming claude is refused for codex too (exit 2)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -qi "claude model"'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext review --prompt-file "$BRIEF" --model codex-fx-mini
chk "C9c a codex-* --model override is accepted and passed through" \
  '[ "$RC" -eq 0 ] && grep -qx "MODEL=codex-fx-mini" "$STUB_LOG"'

# --- C13-C14: compare support — --patch-out and --check ---------------------------
PO="$BUILD/porepo"
new_repo "$PO"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po.patch"
chk "C13 --patch-out writes the patch and does NOT apply it (the caller's tree stays clean)" \
  '[ "$RC" -eq 0 ] && grep -q "^+CODEX WAS HERE$" "$BUILD/po.patch" && [ -z "$(git -C "$PO" status --porcelain)" ] && printf "%s" "$ERR" | grep -q "NOT applied (--patch-out)"'

printf 'dirty\n' > "$PO/wip.txt"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po2.patch"
chk "C13b --patch-out refuses a dirty tree (exit 3) before anything runs" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clean tree" && [ ! -s "$STUB_LOG" ]'
rm -f "$PO/wip.txt"

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext build --level builder --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po3.patch" --output "$BUILD/po3b.patch"
chk "C13c --patch-out with --output is a usage error (exit 2)" '[ "$RC" -eq 2 ]'
AGY_BOUNDARY_CLEARED=1 run_ext review --prompt-file "$BRIEF" --patch-out "$BUILD/po4.patch"
chk "C13d --patch-out outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=buildedit \
  run_ext build --level builder --prompt-file "$BRIEF" --workdir "$PO" --patch-out "$BUILD/po5.patch" \
  --check 'grep -c "CODEX WAS HERE" calc.txt; echo artifact > check-artifact.txt; echo check-ran; exit 3'
chk "C14 --check runs in the worktree after the model: CHECK rc=<n> + output tail, exit code unchanged" \
  '[ "$RC" -eq 0 ] && printf "%s" "$ERR" | grep -qx "CHECK rc=3" && printf "%s" "$ERR" | grep -qx "check-ran" && printf "%s" "$ERR" | grep -qx "1"'
chk "C14b check artifacts never enter the captured patch" \
  '! grep -q "check-artifact" "$BUILD/po5.patch" && grep -q "^+CODEX WAS HERE$" "$BUILD/po5.patch"'

AGY_BOUNDARY_CLEARED=1 run_ext review --prompt-file "$BRIEF" --check true
chk "C14d --check outside build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ]'

# --- I*: --input-dir — a whole tree staged as a copy, never a way out of it -------
IDR=$(new_tmp)
mkdir -p "$IDR/snap/sub/deeper"
printf 'top\n' > "$IDR/snap/top.md"
printf 'deep\n' > "$IDR/snap/sub/deeper/d.md"
ln -s ../top.md "$IDR/snap/sub/inside-link.md"
AGY_BOUNDARY_CLEARED=1 AGY_STAGE_KEEP=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok \
  run_ext read --prompt-file "$BRIEF" --input-dir "$IDR/snap" --input "$DATA"
KEPT=$(kept_stage)
chk "I1 --input-dir stages a COPY of the whole tree at inputs/<basename> (nested files, same bytes), next to --input files" \
  '[ "$RC" -eq 0 ] && [ -n "$KEPT" ] && [ "$(cat "$KEPT/ws/inputs/snap/top.md")" = top ] && [ "$(cat "$KEPT/ws/inputs/snap/sub/deeper/d.md")" = deep ] && [ -f "$KEPT/ws/inputs/note.txt" ]'
chk "I1b a link that stays inside the tree is kept as a link and still resolves inside the COPY" \
  '[ -L "$KEPT/ws/inputs/snap/sub/inside-link.md" ] && [ "$(cat "$KEPT/ws/inputs/snap/sub/inside-link.md")" = top ]'
chk "I1c the prompt footer names the staged tree by absolute path with its file count" \
  'grep -q "^  /.*/ws/inputs/snap/ (a directory: 2 files" "$STUB_PROMPT"'
chk "I1d the caller's tree is untouched (still exactly its three entries)" \
  '[ "$(find "$IDR/snap" | wc -l | tr -d " ")" = 6 ] && [ "$(cat "$IDR/snap/top.md")" = top ]'
[ -n "$KEPT" ] && rm -rf "$KEPT"

mkdir -p "$IDR/leaky" "$IDR/leaky-rel/in" "$IDR/leaky-dir"
printf 'ok\n' > "$IDR/leaky/a.md"
ln -s "$ROOT/projects/secret/secret.txt" "$IDR/leaky/s.md"
printf 'outside\n' > "$IDR/outside.txt"
ln -s ../../outside.txt "$IDR/leaky-rel/in/o.md"
ln -s "$ROOT/projects/secret" "$IDR/leaky-dir/secretdir"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$IDR/leaky"
chk "I2 an --input-dir holding an absolute symlink OUT of the tree is REFUSED (exit 3, names the link), codex never runs" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "holds a symlink that leaves it" && printf "%s" "$ERR" | grep -q "s.md" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$IDR/leaky-rel"
chk "I2b ...and a RELATIVE link climbing out of it (../../) is refused the same way (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "holds a symlink that leaves it" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$IDR/leaky-dir"
chk "I2c ...and a link to a DIRECTORY outside it (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "holds a symlink that leaves it" && [ ! -s "$STUB_LOG" ]'

AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$DENY/clip-creator/inner"
chk "I3 an --input-dir inside a deny-listed repo is REFUSED (exit 3, names clip-creator)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "clip-creator" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$DENY"
chk "I3b an --input-dir with a deny-listed repo BENEATH it is REFUSED (exit 3, names it)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "contains .*clip-creator" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$MARKED"
chk "I3c an --input-dir with a .codex-deny marker beneath it is REFUSED (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "contains .*\.codex-deny" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$LCO/wt"
chk "I3d an --input-dir that is a linked worktree of a .codex-deny repo is REFUSED via its main worktree (exit 3)" \
  '[ "$RC" -eq 3 ] && printf "%s" "$ERR" | grep -q "\.codex-deny" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$ROOT"
chk "I3e --input-dir \$HOME is REFUSED (exit 3)" '[ "$RC" -eq 3 ] && [ ! -s "$STUB_LOG" ]'

mkdir -p "$IDR/big"
dd if=/dev/zero of="$IDR/big/blob.bin" bs=1024 count=2200 2>/dev/null
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$IDR/big" --input-dir-max-mb 1
chk "I4 an --input-dir over --input-dir-max-mb is a usage error (exit 2) naming its size and the cap, codex never runs" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "over the 1 MB cap" && printf "%s" "$ERR" | grep -q -- "--input-dir-max-mb" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" CODEX_STUB_MODE=ok run_ext read --prompt-file "$BRIEF" --input-dir "$IDR/big"
chk "I4b ...the same tree runs under the default 200 MB cap (exit 0)" '[ "$RC" -eq 0 ]'
for badmb in 0 abc -3; do
  AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --input-dir "$IDR/snap" --input-dir-max-mb "$badmb"
  chk "I4c --input-dir-max-mb $badmb is a usage error (exit 2)" '[ "$RC" -eq 2 ] && [ ! -s "$STUB_LOG" ]'
done

new_repo "$IDR/brepo"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext build --level builder --prompt-file "$BRIEF" --workdir "$IDR/brepo" --input-dir "$IDR/snap"
chk "I5 --input-dir in build mode is a usage error (exit 2)" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "read-only modes" && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --input-dir "$IDR/no-such-dir"
chk "I6 a missing --input-dir is a usage error (exit 2)" '[ "$RC" -eq 2 ] && [ ! -s "$STUB_LOG" ]'
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --input-dir "$DATA"
chk "I6b a FILE given as --input-dir is a usage error (exit 2)" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "not a directory"'
mkdir -p "$IDR/note.txt"
AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --input "$DATA" --input-dir "$IDR/note.txt"
chk "I7 an --input file and an --input-dir with the same name are a usage error (exit 2), never one over the other" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "share the name" && [ ! -s "$STUB_LOG" ]'
mkdir -p "$IDR/fifo"
if mkfifo "$IDR/fifo/p" 2>/dev/null; then
  AGY_BOUNDARY_CLEARED=1 TRIAGE_TIERS="$FIX" run_ext read --prompt-file "$BRIEF" --input-dir "$IDR/fifo"
  chk "I8 an --input-dir holding a special file (a fifo) is a usage error (exit 2)" '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q "special file"'
else
  skip "I8 an --input-dir holding a special file" "mkfifo unavailable"
fi
AGY_BOUNDARY_CLEARED=1 run_bounded read --prompt-file "$BRIEF" --input-dir
chk "I9 a trailing --input-dir with no value is exit 2, never a hang" \
  '[ "$RC" -eq 2 ] && printf "%s" "$ERR" | grep -q -- "--input-dir needs a value"'

# --- P11: across this WHOLE suite, no codex run was ever unconfined ---------------
RC=0; ERR=""
chk "P11 every stub run in this suite ran under the sandbox (no SANDBOXED=no line, at least one run logged)" \
  'grep -q "^SANDBOXED=" "$ALL_STUB_LOG" && ! grep -qx "SANDBOXED=no" "$ALL_STUB_LOG"'

# =============================================================================
# Y*: tiers-sync.sh (frontmatter <-> tiers.json) and triage-tiers.sh
# =============================================================================
TSYNC="$REPO_DIR/scripts/tiers-sync.sh"
TTABLE="$REPO_DIR/scripts/triage-tiers.sh"
YR=$(new_tmp)
mkdir -p "$YR/config" "$YR/agents"
cp "$REPO_DIR/config/tiers.json" "$YR/config/tiers.json"
cp "$REPO_DIR"/agents/triage-*.md "$YR/agents/"
cp "$YR/agents/triage-deep-reasoner.md" "$YR/deep.orig"

Y_OUT=$("$TSYNC" --check --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y1 the shipped agents' frontmatter matches the shipped tiers.json (--check clean)" '[ "$RC" -eq 0 ]'

jq '.levels.deep.claude.effort = "max"' "$REPO_DIR/config/tiers.json" > "$YR/config/tiers.json"
Y_OUT=$("$TSYNC" --check --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y2 --check fails on drift, names the agent, and changes nothing" \
  '[ "$RC" -eq 1 ] && printf "%s" "$Y_OUT" | grep -q "triage-deep-reasoner.md" && cmp -s "$YR/agents/triage-deep-reasoner.md" "$YR/deep.orig"'

Y_OUT=$("$TSYNC" --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y3 sync rewrites ONLY the effort: line of the drifted agent" \
  '[ "$RC" -eq 0 ] && grep -qx "effort: max" "$YR/agents/triage-deep-reasoner.md" && [ "$(diff "$YR/deep.orig" "$YR/agents/triage-deep-reasoner.md" | grep -c "^[<>]")" -eq 2 ]'
Y_OUT=$("$TSYNC" --check --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y4 --check is clean again after sync" '[ "$RC" -eq 0 ]'

printf -- '---\nname: triage-extra\nmodel: opus\neffort: low\n---\nbody\n' > "$YR/agents/triage-extra.md"
Y_OUT=$("$TSYNC" --check --root "$YR" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y5 an agent not covered by tiers.json fails --check" \
  '[ "$RC" -eq 1 ] && printf "%s" "$Y_OUT" | grep -q "triage-extra.md is not covered"'

Y_OUT=$(TRIAGE_TIERS="$FIX" "$TTABLE" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y6 triage-tiers.sh prints the level x vendor table (claude, codex) from the file, flags guesses, shows the latest parity note" \
  '[ "$RC" -eq 0 ] && printf "%s" "$Y_OUT" | grep -q "^LEVEL *claude *codex *$" && printf "%s" "$Y_OUT" | grep "^builder" | grep -q "gpt-fx-builder·medium (guess) GUESS" && printf "%s" "$Y_OUT" | grep -q "parity (latest): 2000-02-02 test: fixture parity note"'
Y_OUT=$(TRIAGE_TIERS="$HARNESS/no-such-tiers.json" "$TTABLE" 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y7 triage-tiers.sh with a missing tiers file exits 2" '[ "$RC" -eq 2 ]'
jq '.tuning.challengers.builder.agy = [{"model": "gemini-3.1-pro-high"}]' "$REPO_DIR/config/tiers.json" > "$HARNESS/tiers-agy-challenger.json"
Y_OUT=$(TRIAGE_TIERS="$HARNESS/tiers-agy-challenger.json" "$TTABLE" --bakeoff-json 2>&1); RC=$?; ERR="$Y_OUT"
chk "Y8 an agy bake-off challenger is an invalid tuning block (agy retired)" \
  '[ "$RC" -eq 2 ] && printf "%s" "$Y_OUT" | grep -q "unknown vendor agy"'

echo ""
echo "checks passed: $PASS_COUNT   failed: $FAIL_COUNT   skipped: $SKIP_COUNT"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "EXT-RUN: all checks passed"
  exit 0
else
  echo "EXT-RUN: $FAIL_COUNT check(s) failed"
  exit 1
fi
