.PHONY: lint test drift verify sync mutate

lint:
	./test/lint.sh

test:
	./test/roundtrip.sh
	./test/usage-tally.sh
	node test/workflow-scenarios.mjs

drift:
	./drift.sh

# Sync repo files into the live install (~/.claude) without touching
# CLAUDE.md/settings.json/permissions; .driftignore'd personal forks are skipped.
sync:
	./install.sh --files-only

# Mutation gate: prove the test suite has teeth (killed/survivor/error per
# mutation). Strict since all 10 mutations have covering tests: any survivor
# fails the gate.
mutate:
	./qc/mutate.sh --strict

# One green gate: lint -> drift -> test, fail-fast.
verify: lint drift test
