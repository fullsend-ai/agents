.DEFAULT_GOAL := help
.PHONY: help script-test test

help:
	@echo "Available targets:"
	@echo "  help         - Show this help message"
	@echo "  script-test  - Run agent shell script unit tests"
	@echo "  test         - Alias for script-test"

define run-timed
	@start=$$(date +%s); \
	rc=0; $(1) || rc=$$?; \
	elapsed=$$(($$(date +%s) - $$start)); \
	printf '::debug::script-test timing: %s completed in %ds\n' '$(1)' "$$elapsed"; \
	exit $$rc
endef

script-test:
	$(call run-timed,bash scripts/post-triage-test.sh)
	$(call run-timed,bash scripts/post-prioritize-test.sh)
	$(call run-timed,bash scripts/post-code-test.sh)
	$(call run-timed,bash scripts/post-review-test.sh)
	$(call run-timed,bash scripts/post-fix-test.sh)
	$(call run-timed,bash scripts/post-retro-test.sh)
	$(call run-timed,bash scripts/post-scribe-test.sh)
	$(call run-timed,bash scripts/validate-output-schema-test.sh)

test: script-test
