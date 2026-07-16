.PHONY: test lint check-docs

test:
	go test ./...

lint:
	gofmt -l .

check-docs:
	@echo "Checking AGENTS.md structure..."
	@grep -q "## Error Handling" AGENTS.md && echo "PASS: Error Handling section found" || (echo "FAIL: Missing '## Error Handling' section" && exit 1)
	@grep -q "specific exception" AGENTS.md && echo "PASS: Specific exceptions topic found" || (echo "FAIL: Missing specific exceptions guidance" && exit 1)
	@grep -q "traceback\|stacktrace\|stack trace" AGENTS.md && echo "PASS: Traceback topic found" || (echo "FAIL: Missing traceback guidance" && exit 1)
	@echo "All docs checks passed"
