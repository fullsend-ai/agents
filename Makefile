.DEFAULT_GOAL := help
.PHONY: help script-build check-bundle script-test test

BUNDLE_SRCS := scripts/post-code.src.sh scripts/post-fix.src.sh scripts/post-prioritize.src.sh
BUNDLE_OUTS := $(BUNDLE_SRCS:.src.sh=.sh)

help:
	@echo "Available targets:"
	@echo "  help          - Show this help message"
	@echo "  script-build  - Bundle .src.sh scripts into committed .sh artifacts"
	@echo "  check-bundle  - Verify committed bundles match script-build output"
	@echo "  script-test   - Run agent shell script unit tests"
	@echo "  test          - Alias for script-test"

define run-timed
	@start=$$(date +%s); \
	rc=0; $(1) || rc=$$?; \
	elapsed=$$(($$(date +%s) - $$start)); \
	printf '::debug::script-test timing: %s completed in %ds\n' '$(1)' "$$elapsed"; \
	exit $$rc
endef

script-build: $(BUNDLE_OUTS)

scripts/%.sh: scripts/%.src.sh scripts/bundle-sh.sh
	scripts/bundle-sh.sh -o $@ $<

check-bundle: script-build
	@git diff --exit-code -- $(BUNDLE_OUTS) || \
	  (echo 'Bundled scripts are stale; run make script-build' >&2; exit 1)

SCRIPT_TEST_TARGET ?= source
export SCRIPT_TEST_TARGET

script-test:
	$(call run-timed,bash scripts/bundle-sh-test.sh)
	$(call run-timed,bash scripts/post-failure-report-test.sh)
	$(call run-timed,bash scripts/post-triage-test.sh)
	$(call run-timed,bash scripts/post-prioritize-test.sh)
	$(call run-timed,bash scripts/post-code-test.sh)
	$(call run-timed,bash scripts/post-review-test.sh)
	$(call run-timed,bash scripts/post-fix-test.sh)
	$(call run-timed,bash scripts/post-retro-test.sh)
	$(call run-timed,bash scripts/post-scribe-test.sh)
	$(call run-timed,bash scripts/validate-output-schema-test.sh)
	$(call run-timed,bash .github/scripts/check-e2e-authorization-test.sh)

test: script-test
