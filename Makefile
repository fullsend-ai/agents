.DEFAULT_GOAL := help
.PHONY: help script-build check-bundle script-test test lint lint-fix

BUNDLE_SRCS := scripts/pre-code.src.sh scripts/post-code.src.sh scripts/pre-fix.src.sh scripts/post-fix.src.sh scripts/pre-prioritize.src.sh scripts/post-prioritize.src.sh scripts/pre-retro.src.sh scripts/post-retro.src.sh scripts/pre-review.src.sh scripts/post-review.src.sh scripts/pre-triage.src.sh scripts/post-triage.src.sh
BUNDLE_OUTS := $(BUNDLE_SRCS:.src.sh=.sh)
LIB_DEPS := $(wildcard scripts/lib/*.lib.sh)

SKILLSAW_VERSION := 0.18.0

help:
	@echo "Available targets:"
	@echo "  help          - Show this help message"
	@echo "  script-build  - Bundle .src.sh scripts into committed .sh artifacts"
	@echo "  check-bundle  - Verify committed bundles match script-build output"
	@echo "  script-test   - Run agent shell script unit tests"
	@echo "  test          - Alias for script-test"
	@echo "  lint          - Lint skills/agents/instructions with skillsaw"
	@echo "  lint-fix      - Apply skillsaw's automatic lint fixes"

lint:
	uvx skillsaw==$(SKILLSAW_VERSION) --strict

lint-fix:
	uvx skillsaw==$(SKILLSAW_VERSION) fix

define run-timed
	@start=$$(date +%s); \
	rc=0; $(1) || rc=$$?; \
	elapsed=$$(($$(date +%s) - $$start)); \
	printf '::debug::script-test timing: %s completed in %ds\n' '$(1)' "$$elapsed"; \
	exit $$rc
endef

script-build: $(BUNDLE_OUTS)

scripts/%.sh: scripts/%.src.sh scripts/bundle-sh.sh $(LIB_DEPS)
	scripts/bundle-sh.sh -o $@ $<

check-bundle:
	@tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	for src in $(BUNDLE_SRCS); do \
	  out="$$tmp/$$(basename "$${src%.src.sh}.sh")"; \
	  committed="scripts/$$(basename "$${src%.src.sh}.sh")"; \
	  scripts/bundle-sh.sh -o "$$out" "$$src" || exit 1; \
	  diff -u "$$committed" "$$out" >/dev/null || \
	    { echo "Bundled script stale: $$committed (run make script-build)" >&2; exit 1; }; \
	done

SCRIPT_TEST_TARGET ?= source
export SCRIPT_TEST_TARGET

script-test:
	$(call run-timed,bash scripts/bundle-sh-test.sh)
	$(call run-timed,bash scripts/gitleaks-install-test.sh)
	$(call run-timed,bash scripts/post-failure-report-test.sh)
	$(call run-timed,bash scripts/pr-assignee-test.sh)
	$(call run-timed,bash scripts/labels-test.sh)
	$(call run-timed,bash scripts/post-triage-test.sh)
	$(call run-timed,bash scripts/pre-triage-test.sh)
	$(call run-timed,bash scripts/pre-prioritize-test.sh)
	$(call run-timed,bash scripts/post-prioritize-test.sh)
	$(call run-timed,bash scripts/pre-code-test.sh)
	$(call run-timed,bash scripts/post-code-test.sh)
	$(call run-timed,bash scripts/pre-review-test.sh)
	$(call run-timed,bash scripts/post-review-test.sh)
	$(call run-timed,bash scripts/post-fix-test.sh)
	$(call run-timed,bash scripts/post-retro-test.sh)
	$(call run-timed,bash scripts/pre-scribe-test.sh)
	$(call run-timed,bash scripts/post-scribe-test.sh)
	$(call run-timed,bash scripts/validate-output-schema-test.sh)
	$(call run-timed,bash scripts/gitlint-forbidden-type-scope-test.sh)
	$(call run-timed,bash hack/lint-agent-docs-test.sh)
	$(call run-timed,bash eval/lint-measurements-test.sh)
	$(call run-timed,bash .github/scripts/check-e2e-authorization-test.sh)
	$(call run-timed,bash .github/scripts/select-eval-agents-test.sh)
	$(call run-timed,python3 scripts/process-fix-result-test.py)
	$(call run-timed,bash eval/scripts/scrub-eval-results-test.sh)
	$(call run-timed,bash .github/scripts/check-rollup-result-test.sh)

test: script-test
