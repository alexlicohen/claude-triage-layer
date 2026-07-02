.PHONY: lint test drift verify

lint:
	./test/lint.sh

test:
	./test/roundtrip.sh
	node test/workflow-scenarios.mjs

drift:
	./drift.sh

# One green gate: lint -> drift -> test, fail-fast.
verify: lint drift test
