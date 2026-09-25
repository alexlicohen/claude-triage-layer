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
#   5. Tiers sync: every agent's model:/effort: frontmatter equals
#      config/tiers.json (scripts/tiers-sync.sh --check).
#   5b. Tuning: config/tiers.json's tuning block passes triage-tiers.sh --bakeoff-json.
#   6. Level map: triage-exec.js's CLAUDE_AGENT (level -> Claude agent) equals
#      config/tiers.json levels.*.claude.agent, key for key.
#   6b. triage-compare.js's DEFAULT_ADJUDICATORS (review bake-off) equal
#      config/tiers.json levels.<level>.<vendor> model/effort.
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
  DOC_PATHS="statusline.sh triage.md workflows/triage-exec.js install.sh uninstall.sh scripts/ext-run.sh"
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

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "LINT: all checks passed"
  exit 0
else
  echo "LINT: $FAIL_COUNT check(s) failed"
  exit 1
fi
