# Canonical entry points. `make test` runs the same suite CI runs
# (.github/workflows/test.yml -> tools/run_tests.sh); `make check` is the fast
# subset without the slow mutation pass.
.PHONY: test check lint mutation

test:
	@bash tools/run_tests.sh

check:
	@SKIP_MUTATION=1 bash tools/run_tests.sh

lint:
	@python3 tools/policy_check.py

mutation:
	@python3 tools/mutator.py
