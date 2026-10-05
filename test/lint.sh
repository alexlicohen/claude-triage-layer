#!/bin/bash
# Lint gate for the triage layer.
#   1. `bash -n` (syntax check) on every *.sh in the repo.
#   2. `node --check` on every *.js under workflows/.
#   3. shellcheck (severity=warning) on every *.sh — IF installed. If not,
#      print a loud SKIP and still exit 0 locally (CI always installs the
#      tool, so CI gets the full lint; a missing tool locally must
#      never masquerade as a silent pass, hence the loud message).
#   4. Docs-consistency check: every file path referenced in README.md's
#      install / manual-install sections must exist on disk, and README's
#      claim of "seven subagent definitions" must match the real agent count.
#   4b. No agent file references a fixed /tmp/ext-* scratch path.
#   4c. builder, deep-reasoner and fable-architect keep `disallowedTools: Agent`
#      in their frontmatter (leaf workers: the harness, not prose, stops a spawn).
#   4d. triage.md fits the SessionStart hook: label + file under the 10,000-char
#      additionalContext cap (scripts/triage-context.sh --check), and the file itself
#      within its 9,500-byte budget (headroom under the cap).
#   5. Tiers sync: every agent's model:/effort: frontmatter equals
#      config/tiers.json (scripts/tiers-sync.sh --check).
#   5b. Tuning: config/tiers.json's tuning block passes triage-tiers.sh --bakeoff-json.
#   5c. Pinned ids: every Claude model in config/tiers.json (levels, agents,
#      tuning.challengers) is a concrete id, never an aliasHistory alias, so a
#      model upgrade is an explicit tiers edit (and a fresh ledger history).
#   6. Level map: triage-exec.js's CLAUDE_AGENT (level -> Claude agent) equals
#      config/tiers.json levels.*.claude.agent, key for key.
#   6b. triage-compare.js's DEFAULT_ADJUDICATORS (review bake-off) equal
#      config/tiers.json levels.<level>.<vendor> model/effort.
#   6c. Danger floor: config/tiers.json levels.deep and levels.top name, for every
#      vendor, a model of a family triage-exec.js's DANGER_FAMILIES allows (danger
#      work is lifted to >= deep, so planned danger routing always meets the floor),
#      tokenized by the owner's own modelTokens (evaluated, not copied).
#   6d. One family-token split: parity-report.sh id_tokens splits on the same
#      separators as triage-exec.js modelTokens, the owner.
#   6e. External-reply rule: triage-compare.js / triage-parity.js carry pinned copies of
#      triage-exec.js's classifyExternal() (+ EXTERNAL_REASON_MAX) and
#      classifyCrossReview() (+ CROSS_HEADER); each block must be byte-identical.
#   7. No hard-coded model id outside config/tiers.json (code, config and agent
#      files; an explicit allowlist names each legitimate place and its guard).
#
# Fail-loud: accumulates all failures, exits non-zero if any hard failure
# occurred (shellcheck's absence is NOT a hard failure — it's an explicit,
# printed INCOMPLETE for the local run only).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR" || exit 1

FAIL_COUNT=0
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
ok() { echo "OK:   $1"; }

LINT_ERR=$(mktemp)
trap 'rm -f "$LINT_ERR"' EXIT

# --- 1. bash -n on every *.sh (excluding .git) -------------------------------
SH_FILES=$(find . -path ./.git -prune -o -name '*.sh' -print | sed 's#^\./##')
if [ -z "$SH_FILES" ]; then
  fail "no *.sh files found — that itself looks wrong, refusing to silently pass"
else
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if bash -n "$f" 2>"$LINT_ERR"; then
      ok "bash -n $f"
    else
      fail "bash -n $f"
      cat "$LINT_ERR" >&2
    fi
  done <<EOF
$SH_FILES
EOF
fi

# --- 2. node syntax-check on every *.js under workflows/ ---------------------
# Workflow-DSL scripts have `export const meta = {...}` plus top-level await
# and a top-level `return` — the DSL runs them as an async function body (with
# `meta` extracted). Plain `node --check` parses the file as a module/script
# and rejects the top-level return, so instead strip the leading `export` off
# the meta declaration and parse the remainder with the AsyncFunction
# constructor, mirroring how the DSL actually executes the script.
if command -v node >/dev/null 2>&1; then
  JS_FILES=$(find workflows -name '*.js' 2>/dev/null)
  if [ -z "$JS_FILES" ]; then
    fail "no *.js files found under workflows/ — expected at least triage-exec.js"
  else
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if node -e '
        const fs = require("fs");
        const path = process.argv[1];
        const src = fs.readFileSync(path, "utf8")
          .replace(/^export\s+const\s+meta\b/m, "const meta");
        const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
        try {
          new AsyncFunction(src);
        } catch (e) {
          console.error(e.stack || String(e));
          process.exit(1);
        }
      ' "$f" 2>"$LINT_ERR"; then
        ok "node syntax-check $f"
      else
        fail "node syntax-check $f"
        cat "$LINT_ERR" >&2
      fi
    done <<EOF
$JS_FILES
EOF
  fi
else
  fail "node is not installed — cannot check workflows/*.js (this is a hard failure, not a skip: CI always has node)"
fi

# --- 3. shellcheck (severity=warning), only if installed ---------------------
if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if shellcheck --severity=warning "$f"; then
      ok "shellcheck $f"
    else
      fail "shellcheck $f"
    fi
  done <<EOF
$SH_FILES
EOF
else
  echo "SKIP: shellcheck not installed (lint INCOMPLETE — brew install shellcheck)"
fi

# --- 4. docs-consistency: README paths must exist, agent count must match ----
README="README.md"
if [ ! -f "$README" ]; then
  fail "README.md not found — cannot run docs-consistency check"
else
  # Paths the README's install / manual-install sections claim exist.
  DOC_PATHS="statusline.sh triage.md workflows/triage-exec.js install.sh uninstall.sh scripts/ext-run.sh scripts/triage-context.sh"
  for p in $DOC_PATHS; do
    if [ -e "$p" ]; then
      ok "docs-consistency: $p exists"
    else
      fail "docs-consistency: README references $p but it does not exist"
    fi
  done

  AGENT_COUNT=$(find agents -maxdepth 1 -name 'triage-*.md' | wc -l | tr -d ' ')
  if [ "$AGENT_COUNT" -eq 7 ]; then
    ok "docs-consistency: agents/triage-*.md count is 7, matches README"
  else
    fail "docs-consistency: agents/triage-*.md count is $AGENT_COUNT, README claims 7 (drift)"
  fi

  if grep -qi 'seven subagent definitions' "$README"; then
    ok "docs-consistency: README still claims 'seven subagent definitions'"
  else
    fail "docs-consistency: README no longer says 'seven subagent definitions' — update the doc-consistency check or the README"
  fi
fi

# --- 4b. agent files never use a FIXED /tmp/ext-* path -------------------------
# Parallel bake-off candidates (triage-compare parallel:true) run several
# triage-external wrappers at once; a fixed scratch path lets one overwrite
# another's before/after state. Each invocation uses its own mktemp -d dir.
if FIXED_TMP=$(grep -n '/tmp/ext-' agents/*.md); then
  fail "agents: a fixed /tmp/ext-* path is referenced (use a private mktemp -d dir per invocation):"
  printf '%s\n' "$FIXED_TMP" >&2
else
  ok "agents: no fixed /tmp/ext-* path in any agent file"
fi

# --- 4c. leaf workers cannot spawn subagents -------------------------------------
# builder, deep-reasoner and fable-architect have no `tools:` allowlist, so they
# inherit the Agent tool unless their frontmatter denies it. "Leaf worker" in the
# body is prose; `disallowedTools: Agent` is what the harness enforces.
for LEAF in triage-builder triage-deep-reasoner triage-fable-architect; do
  if awk 'NR == 1 && $0 == "---" { infm = 1; next }
          infm && $0 == "---" { exit }
          infm && /^disallowedTools:/ {
            v = $0; sub(/^disallowedTools:[ \t]*/, "", v); n = split(v, t, /[ \t]*,[ \t]*/)
            for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", t[i]); if (t[i] == "Agent") found = 1 }
          }
          END { exit found ? 0 : 1 }' "agents/$LEAF.md"; then
    ok "leaf-agent: agents/$LEAF.md frontmatter has disallowedTools: Agent"
  else
    fail "leaf-agent: agents/$LEAF.md frontmatter lacks disallowedTools: Agent (it could spawn subagents)"
  fi
done

# --- 4d. triage.md fits the SessionStart hook ------------------------------------
# Over the cap Claude Code delivers only a 2,000-char preview, so the main session
# would silently lose most of the rubric; the hook prints a notice instead, and this
# check keeps it from ever shipping that way.
TRIAGE_MD_MAX=9500
if CTX_OUT=$(./scripts/triage-context.sh --check triage.md 2>&1); then
  ok "triage.md: $CTX_OUT"
else
  fail "triage.md: scripts/triage-context.sh --check failed"
  printf '%s\n' "$CTX_OUT" >&2
fi
TRIAGE_MD_BYTES=$(wc -c < triage.md | tr -d ' ')
if [ "$TRIAGE_MD_BYTES" -le "$TRIAGE_MD_MAX" ]; then
  ok "triage.md: $TRIAGE_MD_BYTES bytes (budget $TRIAGE_MD_MAX)"
else
  fail "triage.md: $TRIAGE_MD_BYTES bytes, over its $TRIAGE_MD_MAX-byte budget — trim it (the hook cap is 10,000 chars with the label)"
fi

# --- 5. tiers sync: agents/*.md model:/effort: must equal config/tiers.json ------
# tiers.json is the one place a model or effort is edited; `make tiers` writes it
# into the frontmatter. A hand edit to either side without the other fails here.
if TIERS_OUT=$(./scripts/tiers-sync.sh --check 2>&1); then
  ok "tiers-sync: agents/*.md frontmatter matches config/tiers.json"
else
  fail "tiers-sync: agents/*.md frontmatter differs from config/tiers.json — run make tiers (or fix tiers.json)"
  printf '%s\n' "$TIERS_OUT" >&2
fi

# --- 5b. tuning block: the inline bake-off / parity-report config is valid --------
# triage-tiers.sh --bakeoff-json owns the tuning schema (sampleRate, maintain, challengerMix,
# challengers per level/vendor, the decision rule, ledger, pause threshold).
if TUNING_OUT=$(TRIAGE_TIERS="$REPO_DIR/config/tiers.json" ./scripts/triage-tiers.sh --bakeoff-json 2>&1 >/dev/null); then
  ok "tuning: config/tiers.json tuning block is valid (triage-tiers.sh --bakeoff-json)"
else
  fail "tuning: config/tiers.json tuning block is invalid"
  printf '%s\n' "$TUNING_OUT" >&2
fi

# --- 5c. pinned Claude ids: no bare alias anywhere a Claude model is configured ----
# An alias (opus, sonnet, ...) can move to a new version silently; a concrete id
# cannot. aliasHistory stays the only place aliases appear (to read old ledger lines).
PIN_OUT=$(jq -r '(.aliasHistory.claude // {} | keys) as $al
  | [ (.levels[]?.claude? | objects | .model), (.agents[]? | objects | .model),
      (.tuning.challengers[]?.claude?[]? | objects | .model) ]
  | map(select((type != "string") or (. as $m | $al | index($m)) != null or (test("^claude-[a-z]+-") | not)))
  | unique | join(", ")' config/tiers.json 2>&1)
if [ -z "$PIN_OUT" ] && [ "$(jq -r '.aliasHistory.claude | type' config/tiers.json 2>/dev/null)" = object ]; then
  ok "pinned-ids: every Claude model in config/tiers.json is a concrete id (aliases only in aliasHistory)"
else
  fail "pinned-ids: config/tiers.json configures a Claude model that is not a concrete id (or has no aliasHistory.claude): ${PIN_OUT:-aliasHistory.claude missing}"
fi

# --- 6. level map: each workflow's CLAUDE_AGENT == tiers.json levels.*.claude.agent --
# The workflows cannot read tiers.json at run time (the DSL has no fs), so each
# carries its own level -> Claude agent map. This keeps them from drifting apart.
if command -v node >/dev/null 2>&1; then
  for WF in workflows/triage-exec.js workflows/triage-compare.js workflows/triage-parity.js; do
  if LEVEL_OUT=$(node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const src = fs.readFileSync(file, "utf8");
    const m = src.match(/^const CLAUDE_AGENT = (\{[^}\n]*\})/m);
    if (!m) { console.error(`no single-line \`const CLAUDE_AGENT = {...}\` in ${file}`); process.exit(1); }
    const wf = Function(`"use strict"; return (${m[1]})`)();
    const tiers = JSON.parse(fs.readFileSync("config/tiers.json", "utf8"));
    const want = Object.fromEntries(Object.entries(tiers.levels || {}).map(([l, v]) => [l, v && v.claude && v.claude.agent]));
    const keys = [...new Set([...Object.keys(wf), ...Object.keys(want)])].sort();
    const bad = keys.filter(k => wf[k] !== want[k]).map(k => `${k}: ${file}=${wf[k]} tiers.json=${want[k]}`);
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' "$WF" 2>&1); then
    ok "level-map: $WF CLAUDE_AGENT matches config/tiers.json levels.*.claude.agent"
  else
    fail "level-map: $WF CLAUDE_AGENT differs from config/tiers.json levels.*.claude.agent"
    printf '%s\n' "$LEVEL_OUT" >&2
  fi
  done

  # 6b. The review bake-off's default adjudicators name a model/effort per vendor; they
  # must be exactly config/tiers.json levels.<level>.<vendor> (the one owner of ids).
  if ADJ_OUT=$(node -e '
    const fs = require("fs");
    const src = fs.readFileSync("workflows/triage-compare.js", "utf8");
    const m = src.match(/^const DEFAULT_ADJUDICATORS = (\[[^\n]*\])$/m);
    if (!m) { console.error("no single-line `const DEFAULT_ADJUDICATORS = [...]` in workflows/triage-compare.js"); process.exit(1); }
    const adj = Function(`"use strict"; return (${m[1]})`)();
    const tiers = JSON.parse(fs.readFileSync("config/tiers.json", "utf8"));
    const bad = adj.map(a => { const t = ((tiers.levels || {})[a.level] || {})[a.vendor] || {};
      return t.model === a.model && t.effort === a.effort ? null : `${a.vendor}@${a.level}: workflow ${a.model}/${a.effort} vs tiers.json ${t.model}/${t.effort}`; }).filter(Boolean);
    if (adj.length < 2) bad.push("fewer than two default adjudicators");
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' 2>&1); then
    ok "review-adjudicators: triage-compare.js DEFAULT_ADJUDICATORS match config/tiers.json levels"
  else
    fail "review-adjudicators: triage-compare.js DEFAULT_ADJUDICATORS differ from config/tiers.json levels"
    printf '%s\n' "$ADJ_OUT" >&2
  fi

  # 6c. The danger floor (policy: DANGER_FAMILIES in triage-exec.js) against the
  # data: every vendor's deep and top model must be a floor family — a whole token
  # of the id, split on - . _ : + @ (the workflow's own notion).
  if DF_OUT=$(node -e '
    const fs = require("fs");
    const src = fs.readFileSync("workflows/triage-exec.js", "utf8");
    const m = src.match(/^const DANGER_FAMILIES = (\{[^\n]*\})$/m);
    if (!m) { console.error("no single-line `const DANGER_FAMILIES = {...}` in workflows/triage-exec.js"); process.exit(1); }
    const fam = Function(`"use strict"; return (${m[1]})`)();
    // The family-token split is the OWNER\x27s (triage-exec.js modelTokens), evaluated
    // here, never a copy that could drift from what the workflow enforces.
    const t = src.match(/^const modelTokens = (m => [^\n]*)$/m);
    if (!t) { console.error("no single-line `const modelTokens = m => ...` in workflows/triage-exec.js"); process.exit(1); }
    const modelTokens = Function(`"use strict"; return (${t[1]})`)();
    const tiers = JSON.parse(fs.readFileSync("config/tiers.json", "utf8"));
    const bad = [];
    for (const level of ["deep", "top"]) {
      const byV = (tiers.levels || {})[level];
      if (!byV || typeof byV !== "object") { bad.push(`levels.${level} missing`); continue; }
      for (const [v, e] of Object.entries(byV)) {
        const toks = modelTokens(e && e.model);
        if (!(fam[v] || []).some(f => toks.includes(f))) bad.push(`levels.${level}.${v}.model ${e && e.model} is not a danger-floor family (${(fam[v] || []).join("|") || "none for this vendor"})`);
      }
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' 2>&1); then
    ok "danger-floor: config/tiers.json levels.deep/top models are DANGER_FAMILIES families for every vendor"
  else
    fail "danger-floor: config/tiers.json levels.deep/top name a model below triage-exec.js DANGER_FAMILIES"
    printf '%s\n' "$DF_OUT" >&2
  fi

  # 6d. ONE family-token split. Owner: workflows/triage-exec.js `modelTokens` (the
  # danger floor's notion of a model family token). scripts/parity-report.sh cannot
  # import JS, so its jq `id_tokens` (cheapness by family) must split on exactly the
  # same separator set: checked here against the owner, never against a copy.
  if SPLIT_OUT=$(node -e '
    const fs = require("fs");
    const own = fs.readFileSync("workflows/triage-exec.js", "utf8").match(/^const modelTokens = m => [^\n]*\.split\(\/(\[[^\]\n]+\])\/\)/m);
    const pr = fs.readFileSync("scripts/parity-report.sh", "utf8").match(/^def id_tokens: [^\n]*splits\("(\[[^\]\n]+\])"\)/m);
    if (!own) { console.error("no `const modelTokens = m => ....split(/[...]/)` in workflows/triage-exec.js (the owner)"); process.exit(1); }
    if (!pr) { console.error("no `def id_tokens: ... splits(\"[...]\")` in scripts/parity-report.sh"); process.exit(1); }
    const set = c => [...new Set(c.slice(1, -1).replace(/\\/g, ""))].sort().join("");
    if (set(own[1]) !== set(pr[1])) { console.error(`parity-report.sh id_tokens splits on ${pr[1]}, the owner triage-exec.js modelTokens on ${own[1]}`); process.exit(1); }
  ' 2>&1); then
    ok "family-split: parity-report.sh id_tokens splits on the same separators as triage-exec.js modelTokens (the owner)"
  else
    fail "family-split: parity-report.sh id_tokens and triage-exec.js modelTokens (the owner) split model ids differently"
    printf '%s\n' "$SPLIT_OUT" >&2
  fi

  # 6e. One external-reply rule: triage-compare.js and triage-parity.js carry PINNED
  # copies of triage-exec.js's classifyExternal() (with EXTERNAL_REASON_MAX) and
  # classifyCrossReview() (with CROSS_HEADER); each block must be byte-identical.
  if CLS_OUT=$(node -e '
    const fs = require("fs");
    const block = (src, start) => { const i = src.indexOf(`\n${start}`); if (i < 0) return null;
      const j = src.indexOf("\n}\n", i); return j < 0 ? null : src.slice(i + 1, j + 2); };
    const starts = ["const EXTERNAL_REASON_MAX = ", "const CROSS_HEADER = "];
    const files = ["workflows/triage-exec.js", "workflows/triage-compare.js", "workflows/triage-parity.js"];
    const bad = [];
    for (const s of starts) {
      const [own, ...copies] = files.map(f => [f, block(fs.readFileSync(f, "utf8"), s)]);
      if (!own[1]) { bad.push(`${own[0]}: no block starting "${s}"`); continue; }
      for (const [f, b] of copies) if (b !== own[1]) bad.push(`${f}: the block starting "${s}" ${b ? "differs from" : "is missing; owner is"} ${own[0]}`);
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
  ' 2>&1); then
    ok "external-reply rule: classifyExternal/classifyCrossReview copies in triage-compare.js and triage-parity.js match triage-exec.js"
  else
    fail "external-reply rule: classifyExternal/classifyCrossReview copies drifted from triage-exec.js"
    printf '%s\n' "$CLS_OUT" >&2
  fi

  # Workflow-DSL constraints (the runtime throws on these at run time, so catch them
  # here): meta is a pure literal, and no Date.now()/Math.random()/argless new Date().
  for WF in workflows/*.js; do
    if DSL_OUT=$(node -e '
      const src = require("fs").readFileSync(process.argv[1], "utf8");
      const errs = [];
      const code = src.replace(/\/\/[^\n]*/g, "");
      if (/\bDate\.now\s*\(/.test(code)) errs.push("Date.now()");
      if (/\bMath\.random\s*\(/.test(code)) errs.push("Math.random()");
      if (/\bnew\s+Date\s*\(\s*\)/.test(code)) errs.push("argless new Date()");
      const m = src.match(/^export const meta = (\{[\s\S]*?\n\})/m);
      if (!m) errs.push("no `export const meta = {...}` block");
      else {
        // Pure literal: once string literals, keys, numbers and true/false/null are
        // removed, only { } [ ] , : may remain (no identifiers, calls, spreads, templates).
        const rest = m[1]
          .replace(/"(?:[^"\\]|\\.)*"|\x27(?:[^\x27\\]|\\.)*\x27/g, "0")
          .replace(/[A-Za-z_$][\w$]*\s*:/g, ":")
          .replace(/\b(?:true|false|null)\b|-?\d+(?:\.\d+)?/g, "");
        if (!/^[\s{}\[\],:]*$/.test(rest)) errs.push("meta is not a pure literal (left over: " + rest.replace(/[\s{}\[\],:]+/g, " ").trim().slice(0, 80) + ")");
      }
      if (errs.length) { console.error(errs.join("\n")); process.exit(1); }
    ' "$WF" 2>&1); then
      ok "dsl-constraints: $WF (pure-literal meta, no Date.now/Math.random/argless new Date)"
    else
      fail "dsl-constraints: $WF"
      printf '%s\n' "$DSL_OUT" >&2
    fi
  done
fi

# --- 7. no hard-coded model ids outside config/tiers.json --------------------------
# config/tiers.json is the one owner of every model id (AGENTS.md › Single owners);
# an id typed into code goes stale silently when a tier is upgraded. Scanned: every
# code/config file (*.sh *.js *.mjs *.json *.yml Makefile), agents/*.md and triage.md
# (the installed rubric: an id there is routing policy, so it names DANGER_FAMILIES or
# tiers.json instead); full-line code comments are skipped (an example in prose is not
# configuration). Not scanned: the owner itself, test/ (fixtures pin ids on purpose),
# qc/ (mutations plant them) and prose docs (README, CHANGELOG, AGENTS.md, scripts/README).
# ALLOWLIST: places an id legitimately lives outside the owner, each with its guard:
#   agents/*.md          `model: ` frontmatter     written by make tiers (check 5)
#   install.sh           LEGACY_SUBAGENT_MODELS=   frozen pre-marker defaults, never upgraded
#   triage-compare.js    DEFAULT_ADJUDICATORS =    tied to tiers levels (check 6b); its
#                        help text (REVIEW_USAGE) is built from it, never typed
MODEL_ID_RE='(claude-[a-z]+-[0-9][0-9a-z-]*|gpt-[0-9]+(\.[0-9]+)?-[a-z][a-z0-9-]*)'
model_id_allowed() { # FILE LINE -> 0 when the allowlist covers it
  case "$1" in
    agents/*.md) printf '%s' "$2" | grep -q '^model: ' ;;
    install.sh) printf '%s' "$2" | grep -q '^LEGACY_SUBAGENT_MODELS=' ;;
    workflows/triage-compare.js) printf '%s' "$2" | grep -q '^const DEFAULT_ADJUDICATORS = ' ;;
    *) return 1 ;;
  esac
}
MID_HITS=""
MID_FILES=$( { find . \( -path ./.git -o -path ./test -o -path ./qc -o -path './.?*' \) -prune -o -type f \
    \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.json' -o -name '*.yml' -o -name Makefile \) -print
  find ./agents -maxdepth 1 -type f -name '*.md' -print 2>/dev/null; echo ./triage.md; } | sed 's#^\./##' | grep -vx 'config/tiers.json' | sort -u)
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in *.js|*.mjs) cmt='^[[:space:]]*(//|\*|/\*)' ;; *.json|*.md) cmt='^$' ;; *) cmt='^[[:space:]]*#' ;; esac
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    n="${hit%%:*}"; line="${hit#*:}"
    printf '%s' "$line" | grep -Eq "$cmt" && continue
    model_id_allowed "$f" "$line" && continue
    MID_HITS="${MID_HITS}${f}:${n}: $(printf '%s' "$line" | grep -Eo "$MODEL_ID_RE" | head -n 1)
"
  done <<MIDHITS
$(grep -nE "$MODEL_ID_RE" "$f" 2>/dev/null)
MIDHITS
done <<MIDFILES
$MID_FILES
MIDFILES
if [ -z "$MID_HITS" ]; then
  ok "model-ids: no hard-coded model id outside config/tiers.json (allowlist: agents model:, LEGACY_SUBAGENT_MODELS, DEFAULT_ADJUDICATORS)"
else
  fail "model-ids: hard-coded model id(s) outside config/tiers.json; read it from tiers.json (or allowlist it here with its guard):"
  printf '%s' "$MID_HITS" >&2
fi

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "LINT: all checks passed"
  exit 0
else
  echo "LINT: $FAIL_COUNT check(s) failed"
  exit 1
fi
