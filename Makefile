.PHONY: lint test drift verify sync mutate tiers

lint:
	./test/lint.sh

test:
	./test/roundtrip.sh
	./test/usage-tally.sh
	./test/ext-run.sh
	node test/workflow-scenarios.mjs

drift:
	./drift.sh

# Sync repo files into the live install (~/.claude) without touching
# CLAUDE.md/settings.json/permissions; .driftignore'd personal forks are skipped.
sync:
	./install.sh --files-only

# Rewrite agents/*.md model:/effort: frontmatter from config/tiers.json (the one
# place a model or effort is edited). A no-op when they already agree; lint fails
# while they disagree.
tiers:
	./scripts/tiers-sync.sh

# Mutation gate: prove the test suite has teeth (killed/survivor/error per
# mutation). Strict since all 27 mutations have covering tests: any survivor
# fails the gate.
mutate:
	./qc/mutate.sh --strict

# One green gate: lint -> drift -> test, fail-fast.
verify: lint drift test
