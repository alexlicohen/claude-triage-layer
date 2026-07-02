#!/usr/bin/env bash
#
# triage-stats.sh — cross-session routing statistics for the model-triage layer.
#
# WHAT IT DOES
#   Where triage-usage.sh answers "what did THIS session's subagents cost?", this answers
#   "how is the triage layer being ROUTED over many sessions?" — data for tuning the
#   routing rules in triage.md (is triage-builder over-/under-used? does quick-task get
#   spawned at all? where do tokens go per week?). It aggregates every spawned subagent
#   across a whole project (all its sessions) or across every project.
#
#   Output (stdout, read-only, counts only — never message content):
#     1. a per-tier table:   sessions seen · spawn count · total & median peak-context tokens
#     2. a per-week rollup:   week x tier spawn counts
#     3. a non-triage table:  the same, for non-triage subagents (kept OUT of the tier stats)
#     4. an escalation-marker line, labelled as a LOWER BOUND (see "ESCALATION" below).
#
# WHAT IT READS  (see scripts/README.md for the full schema + limits)
#   The same on-disk layout triage-usage.sh documents:
#     ~/.claude/projects/<slug>/<session-id>.jsonl              <- orchestrator (EXCLUDED)
#     ~/.claude/projects/<slug>/<session-id>/subagents/
#         agent-<agentId>.jsonl        <- one subagent transcript (assistant lines carry
#                                         .message.model, .message.usage, and .timestamp)
#         agent-<agentId>.meta.json    <- {agentType, description, toolUseId, spawnDepth}
#   Only subagent transcripts are read; the orchestrator's own <session-id>.jsonl is never
#   opened ("orchestrator excluded"), matching triage-usage.sh.
#
# THE PEAK METRIC IS triage-usage.sh's METRIC, UNCHANGED
#   Per subagent: peak context = max over assistant turns of
#       (input_tokens + cache_creation_input_tokens + cache_read_input_tokens).
#   This equals the per-subagent figure Claude Code displays; verified identical to
#   triage-usage.sh on real transcripts. triage-usage.sh remains the single owner of that
#   metric's DEFINITION — this script only aggregates it across sessions. A subagent's tier
#   is its meta.json .agentType.
#
# WEEK GROUPING — WHY THE EMBEDDED TIMESTAMP, NOT mtime
#   Each transcript line carries an ISO-8601 UTC .timestamp (e.g. 2026-07-02T02:30:02.177Z).
#   We use the earliest such timestamp in a subagent's transcript as its spawn time, and
#   bucket by ISO week (%G-W%V). This is chosen over file mtime because the embedded
#   timestamp is (a) present in every transcript line observed, (b) unambiguously UTC, and
#   (c) immune to file copies / rsync / git checkouts / backups that reset mtime — on this
#   machine a sampled file's mtime disagreed with its embedded timestamp by hours.
#
# ESCALATION IS A LABELLED LOWER BOUND, NOT A CENSUS
#   Escalation chains are NOT reliably recorded on disk. The only escalation signal available
#   is free-text in meta.json .description (the /triage-run "redo:" / "deep<-fable:" labels,
#   or orchestrator hints like "escalate"/"retry"/"prior attempt"). But most subagents carry
#   NO description at all (on this machine: ~24% do), and the markers are near-absent in
#   practice. So this script scans the description-bearing minority for those markers and
#   reports the hit count EXPLICITLY as a lower bound over that minority — never as a rate of
#   escalation. Fail-loud principle: an inference we cannot make reliably is labelled, not faked.
#
# FAIL-LOUD
#   No ~/.claude/projects, or the scoped dir does not exist -> explicit error + non-zero exit.
#   No subagent transcripts anywhere in scope (or all unparseable) -> INCOMPLETE + non-zero.
#   Per-file parse failures are COUNTED and reported ("N unreadable — skipped"), never dropped.
#
# PORTABILITY: bash 3.2 (macOS default) + jq. BSD-safe (BSD `date -v`, no `stat -c`,
#   no `readlink -f`, no GNU-only flags, no associative arrays). Read-only.

set -u

PROG="$(basename "$0")"

# ---- exit codes (aligned with triage-usage.sh) -----------------------------
EX_OK=0
EX_USAGE=1      # bad invocation
EX_NOTFOUND=2   # given --project path could not be resolved
EX_NOPROJ=3     # ~/.claude/projects (or default project dir) unresolvable
EX_INCOMPLETE=5 # no subagent transcripts in scope, or all unparseable
EX_NOJQ=6       # jq not installed

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit "$2"; }

usage() {
  cat >&2 <<EOF
$PROG — cross-session routing statistics for the triage layer (read-only, counts only).

Usage: $PROG [--project DIR | --all] [--weeks N]

  (default)        Aggregate every session of THIS cwd's project
                   (~/.claude/projects/<slug-of-\$PWD>).
  --project DIR    Aggregate a specific project. DIR may be a Claude project dir
                   (e.g. ~/.claude/projects/<slug>) or a working directory whose
                   slug names one.
  --all            Aggregate every project under ~/.claude/projects.
  --weeks N        Only count subagents spawned within the last N weeks
                   (default: 4). N=0 means no window (all time).
  -h, --help       Show this help.

Output: per-tier table, per-week rollup, non-triage table, and an escalation-marker
lower-bound line. See scripts/README.md for what each stat means and its limits.
EOF
}

# ---- parse args ------------------------------------------------------------
SCOPE="default"   # default | project | all
PROJECT_ARG=""
WEEKS=4

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)     SCOPE="all" ;;
    --project) shift; [ "$#" -gt 0 ] || die "--project needs a DIR argument (use -h)" "$EX_USAGE"
               SCOPE="project"; PROJECT_ARG="$1" ;;
    --weeks)   shift; [ "$#" -gt 0 ] || die "--weeks needs an N argument (use -h)" "$EX_USAGE"
               WEEKS="$1" ;;
    -h|--help) usage; exit "$EX_OK" ;;
    *)         die "unknown argument: $1 (use -h)" "$EX_USAGE" ;;
  esac
  shift
done

case "$WEEKS" in
  ''|*[!0-9]*) die "--weeks must be a non-negative integer, got: $WEEKS" "$EX_USAGE" ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required but not found on PATH" "$EX_NOJQ"

# ---- resolve scope root ----------------------------------------------------
# slug(): reproduce Claude Code's project-dir slug — every non-alphanumeric char in an
# absolute path becomes '-' (identical to triage-usage.sh).
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

PROJECTS_ROOT="$HOME/.claude/projects"
ROOT=""
SCOPE_DESC=""

case "$SCOPE" in
  all)
    [ -d "$PROJECTS_ROOT" ] || die "no Claude projects dir: $PROJECTS_ROOT" "$EX_NOPROJ"
    ROOT="$PROJECTS_ROOT"
    SCOPE_DESC="all projects under $PROJECTS_ROOT"
    ;;
  project)
    # Resolve slug-first: a working-directory path (e.g. /Users/alex/projects/foo) usually
    # exists literally AND maps to a ~/.claude/projects/<slug> dir — the user means the latter.
    # Fall back to treating the arg as a literal project dir (e.g. ~/.claude/projects/<slug>).
    if [ -d "$PROJECTS_ROOT/$(slug "$PROJECT_ARG")" ]; then
      ROOT="$PROJECTS_ROOT/$(slug "$PROJECT_ARG")"
    elif [ -d "$PROJECT_ARG" ]; then
      ROOT="${PROJECT_ARG%/}"
    else
      die "no such project dir: $PROJECT_ARG (and no slug match under $PROJECTS_ROOT)" "$EX_NOTFOUND"
    fi
    SCOPE_DESC="project $ROOT"
    ;;
  *)
    [ -d "$PROJECTS_ROOT" ] || die "no Claude projects dir: $PROJECTS_ROOT (pass --project)" "$EX_NOPROJ"
    ROOT="$PROJECTS_ROOT/$(slug "$PWD")"
    [ -d "$ROOT" ] || die "no Claude project dir for this cwd: $ROOT (pass --project or --all)" "$EX_NOPROJ"
    SCOPE_DESC="current project $ROOT"
    ;;
esac

# ---- week window cutoff ----------------------------------------------------
# BSD date. WEEKS=0 -> no cutoff. String-compare against the spawn date (ISO dates sort
# lexicographically), so no per-row date arithmetic is needed.
CUTOFF=""
if [ "$WEEKS" -gt 0 ]; then
  CUTOFF="$(date -v-"${WEEKS}"w +%Y-%m-%d 2>/dev/null)" \
    || die "could not compute a date cutoff (BSD 'date -v' required)" "$EX_USAGE"
fi

# ---- classifiers -----------------------------------------------------------
# A triage tier is any agentType beginning 'triage-'. Everything else is non-triage.
# An empty/missing agentType is bucketed as 'other' (non-triage).
is_triage() { case "$1" in triage-*) return 0 ;; *) return 1 ;; esac; }

# ---- scan ------------------------------------------------------------------
TMP="$(mktemp "${TMPDIR:-/tmp}/triage-stats.XXXXXX")" || die "could not create temp file" "$EX_USAGE"
trap 'rm -f "$TMP"' EXIT

n_seen=0      # agent transcripts encountered
n_bad=0       # transcripts with no readable assistant/usage records
n_outwin=0    # in-scope but outside the --weeks window
n_kept=0      # counted (in-window, parseable)
n_desc=0      # kept subagents that carry a non-empty description
n_esc=0       # kept subagents whose description matches an escalation marker

# find is invoked once; the loop runs in the current shell (process substitution, NOT a
# pipe) so the counters above persist. Filenames here never contain spaces/newlines.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  n_seen=$((n_seen + 1))

  # ONE jq pass over the transcript (streaming; 2>/dev/null tolerates a partial trailing
  # line in a live session), reduced by awk into: peak<TAB>cum_out<TAB>spawn-date. (The tier
  # is meta.json .agentType, so the transcript's model field is not needed here.)
  red="$(jq -r 'select(.type=="assistant" and (.message.usage!=null))
        | [ ((.message.usage.input_tokens//0)+(.message.usage.cache_creation_input_tokens//0)+(.message.usage.cache_read_input_tokens//0)),
            (.message.usage.output_tokens//0),
            (.timestamp//"") ] | @tsv' "$f" 2>/dev/null \
      | awk -F'\t' '
          NR==1 { peak=$1; spawn=$3 }
          { cum+=$2; if ($1>peak) peak=$1
            if ($3!="" && (spawn=="" || $3<spawn)) spawn=$3 }
          END { if (NR>0) printf "%d\t%d\t%s\n", peak, cum, substr(spawn,1,10) }')"

  if [ -z "$red" ]; then
    [ -s "$f" ] && n_bad=$((n_bad + 1))   # non-empty but no usable usage records
    continue
  fi

  peak="${red%%	*}"; rest="${red#*	}"
  cum_out="${rest%%	*}"
  sdate="${rest##*	}"

  # week window filter
  if [ -n "$CUTOFF" ]; then
    if [ -z "$sdate" ] || [ "$sdate" \< "$CUTOFF" ]; then
      n_outwin=$((n_outwin + 1)); continue
    fi
  fi

  # session id = the dir two levels up from the transcript (.../<sess>/subagents/agent-*.jsonl)
  sess="$(basename "$(dirname "$(dirname "$f")")")"

  # meta.json: ONE jq pass returns agentType + two booleans (has-description, matches an
  # escalation marker). The description text is tested INSIDE jq and never enters the shell.
  meta="${f%.jsonl}.meta.json"
  atype="other"; hd=0; he=0
  if [ -f "$meta" ]; then
    mline="$(jq -r '
        (.agentType // "other") as $t
      | (.description // "") as $d
      | ($d | ascii_downcase) as $dl
      | [ $t,
          (if $d=="" then 0 else 1 end),
          (if ($dl|test("escalat|retry|redo:|prior attempt|failed attempt|previous attempt|deep.{0,3}fable")) then 1 else 0 end)
        ] | @tsv' "$meta" 2>/dev/null)"
    if [ -n "$mline" ]; then
      atype="${mline%%	*}"; mrest="${mline#*	}"
      hd="${mrest%%	*}"; he="${mrest##*	}"
      [ -n "$atype" ] || atype="other"
    fi
  fi

  if is_triage "$atype"; then tri=true; else tri=false; fi

  n_kept=$((n_kept + 1))
  n_desc=$((n_desc + hd))
  n_esc=$((n_esc + he))

  # emit one intermediate JSON record (fields are all slug/uuid/int-safe — no escaping needed)
  printf '{"t":"%s","tri":%s,"peak":%d,"out":%d,"date":"%s","sess":"%s"}\n' \
    "$atype" "$tri" "$peak" "$cum_out" "$sdate" "$sess" >> "$TMP"

done < <(find "$ROOT" -type f -name 'agent-*.jsonl' 2>/dev/null)

# ---- fail-loud gates -------------------------------------------------------
if [ "$n_seen" -eq 0 ]; then
  die "INCOMPLETE: no subagent transcripts under $ROOT — nothing to aggregate" "$EX_INCOMPLETE"
fi
if [ "$n_kept" -eq 0 ]; then
  if [ "$n_outwin" -gt 0 ]; then
    die "INCOMPLETE: all $n_outwin subagent(s) in scope fall outside the last ${WEEKS}-week window (raise --weeks or use --weeks 0)" "$EX_INCOMPLETE"
  fi
  die "INCOMPLETE: found $n_seen subagent transcript(s) under $ROOT but none had readable token usage${n_bad:+ ($n_bad unparseable)}" "$EX_INCOMPLETE"
fi

# ---- formatting helpers ----------------------------------------------------
# kfmt N -> "0" for exactly zero, else nearest k (matches triage-usage.sh's rubric style).
kfmt() {
  if [ "$1" -eq 0 ] 2>/dev/null; then printf '0'; else
    awk -v n="$1" 'BEGIN{printf "%.0fk", n/1000}'
  fi
}

WINDOW_DESC="last ${WEEKS} week(s)"
[ "$WEEKS" -eq 0 ] && WINDOW_DESC="all time"

printf 'Triage routing stats — %s\n' "$SCOPE_DESC"
printf 'Window: %s%s | subagents: %d counted' \
  "$WINDOW_DESC" "$([ -n "$CUTOFF" ] && printf ' (since %s)' "$CUTOFF")" "$n_kept"
[ "$n_outwin" -gt 0 ] && printf ', %d outside window' "$n_outwin"
[ "$n_bad" -gt 0 ] && printf ', %d unreadable — skipped' "$n_bad"
printf '\n\n'

# ---- 1. per-tier table -----------------------------------------------------
# jq: group the triage records by tier -> tier, distinct-sessions, spawns, total & median peak.
AGG_TIER="$(jq -s -r '
    def median: sort as $s | ($s|length) as $n
      | if $n==0 then 0
        elif ($n%2)==1 then $s[($n/2|floor)]
        else (($s[$n/2-1] + $s[$n/2]) / 2 | floor) end;
    map(select(.tri))
    | group_by(.t)[]
    | [ .[0].t, (map(.sess)|unique|length), length, (map(.peak)|add), (map(.peak)|median) ]
    | @tsv' "$TMP")"

# fetch one tier row (or empty) from AGG_TIER
tier_row() { printf '%s\n' "$AGG_TIER" | awk -F'\t' -v t="$1" '$1==t{print;exit}'; }

printf 'TRIAGE TIERS (peak-context tokens; orchestrator excluded)\n'
printf '%-24s %8s %7s %10s %10s\n' TIER SESSIONS SPAWNS TOTAL MEDIAN
# canonical order first so "is builder under-used / does quick-task fire" is always visible,
# even at zero; then any unexpected triage-* tier not in the canonical set.
CANON="triage-quick-task triage-builder triage-deep-reasoner triage-fable-architect triage-reviewer"
printed=""
for t in $CANON; do
  r="$(tier_row "$t")"
  if [ -n "$r" ]; then
    s="$(printf '%s' "$r" | cut -f2)"; sp="$(printf '%s' "$r" | cut -f3)"
    tot="$(printf '%s' "$r" | cut -f4)"; med="$(printf '%s' "$r" | cut -f5)"
    printf '%-24s %8s %7s %10s %10s\n' "$t" "$s" "$sp" "$(kfmt "$tot")" "$(kfmt "$med")"
  else
    printf '%-24s %8s %7s %10s %10s\n' "$t" 0 0 0 -
  fi
  printed="$printed $t"
done
# any triage-* tier observed but not canonical (future-proofing)
printf '%s\n' "$AGG_TIER" | while IFS='	' read -r t s sp tot med; do
  [ -n "$t" ] || continue
  case " $printed " in *" $t "*) continue ;; esac
  printf '%-24s %8s %7s %10s %10s\n' "$t" "$s" "$sp" "$(kfmt "$tot")" "$(kfmt "$med")"
done

# ---- 2. per-week rollup (week x tier spawn counts) -------------------------
printf '\nPER-WEEK SPAWN COUNTS (ISO week, UTC; triage tiers)\n'
printf '%-9s %6s %8s %6s %6s %7s %7s\n' WEEK quick builder deep fable review total
jq -s -r '
    def wk: if .date=="" then "unknown"
            else (.date|strptime("%Y-%m-%d")|mktime|strftime("%G-W%V")) end;
    def cnt($t): map(select(.t==$t))|length;
    map(select(.tri) | . + {week: wk})
    | group_by(.week)[]
    | [ .[0].week,
        cnt("triage-quick-task"), cnt("triage-builder"), cnt("triage-deep-reasoner"),
        cnt("triage-fable-architect"), cnt("triage-reviewer"), length ]
    | @tsv' "$TMP" \
  | sort \
  | while IFS='	' read -r wk q b d fa rv tot; do
      [ -n "$wk" ] || continue
      printf '%-9s %6s %8s %6s %6s %7s %7s\n' "$wk" "$q" "$b" "$d" "$fa" "$rv" "$tot"
    done

# ---- 3. non-triage subagents (kept OUT of the tier stats) ------------------
AGG_NON="$(jq -s -r '
    map(select(.tri|not))
    | group_by(.t)[]
    | [ .[0].t, (map(.sess)|unique|length), length, (map(.peak)|add) ]
    | @tsv' "$TMP" | sort -t'	' -k3 -nr)"
if [ -n "$AGG_NON" ]; then
  printf '\nNON-TRIAGE SUBAGENTS (excluded from tier stats above)\n'
  printf '%-24s %8s %7s %10s\n' TYPE SESSIONS SPAWNS TOTAL
  printf '%s\n' "$AGG_NON" | while IFS='	' read -r t s sp tot; do
    [ -n "$t" ] || continue
    printf '%-24s %8s %7s %10s\n' "$t" "$s" "$sp" "$(kfmt "$tot")"
  done
fi

# ---- 4. escalation-marker lower bound --------------------------------------
printf '\nESCALATION MARKERS (LOWER BOUND — not an escalation rate)\n'
if [ "$n_desc" -eq 0 ]; then
  printf '  none derivable: 0 of %d counted subagents carry a description to scan.\n' "$n_kept"
else
  printf '  %d subagent(s) whose description matches an escalation marker\n' "$n_esc"
  printf '  (out of %d with any description; %d of %d counted subagents have none).\n' \
    "$n_desc" "$((n_kept - n_desc))" "$n_kept"
fi
printf '  Escalations are not recorded on disk; this scans meta.json .description for\n'
printf '  redo:/deep<-fable:/escalate/retry/prior-attempt markers only. Treat as a floor.\n'

exit "$EX_OK"
