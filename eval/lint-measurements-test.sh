#!/usr/bin/env bash
# lint-measurements-test.sh — Tests for eval/lint-measurements.sh
#
# Run from the repo root:
#   bash eval/lint-measurements-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINTER="${SCRIPT_DIR}/lint-measurements.sh"

FAILURES=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

VALID_YAML='---
agent: code
measurements:
  - id: em-001
    scorer: trace_fitness
    version: 1
'

# run_case NAME YAML EXPECTED_EXIT [EXPECTED_OUTPUT_SUBSTRING] [FILENAME]
run_case() {
  local name="$1" yaml="$2" expected_exit="$3" expected_substring="${4:-}" filename="${5:-code.yaml}"

  local case_dir="${WORKDIR}/${name}"
  mkdir -p "${case_dir}/eval/measurements" "${case_dir}/agents"
  printf '%s\n' "# Code Agent" > "${case_dir}/agents/code.md"
  if [[ -n "$yaml" ]]; then
    printf '%s' "$yaml" > "${case_dir}/eval/measurements/${filename}"
  fi

  local output
  local actual_exit=0
  output="$(REPO_ROOT="${case_dir}" MEASUREMENTS_DIR="${case_dir}/eval/measurements" AGENTS_DIR="${case_dir}/agents" "${LINTER}" 2>&1)" || actual_exit=$?

  if [[ "${actual_exit}" != "${expected_exit}" ]]; then
    echo "FAIL: ${name} (exit ${actual_exit}, expected ${expected_exit})"
    echo "${output}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_substring}" ]] && [[ "${output}" != *"${expected_substring}"* ]]; then
    echo "FAIL: ${name} (missing expected output: '${expected_substring}')"
    echo "${output}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${name}"
}

run_case "valid-manifest-passes" \
  "${VALID_YAML}" 0 "code.yaml: OK"

run_case "unknown-scorer" \
  "---
agent: code
measurements:
  - id: em-001
    scorer: trace-fitness
    version: 1
" 1 "unknown scorer 'trace-fitness'"

run_case "unknown-agent" \
  "---
agent: not-an-agent
measurements:
  - id: em-001
    scorer: trace_fitness
    version: 1
" 1 "has no agents/not-an-agent.md" "not-an-agent.yaml"

run_case "filename-agent-mismatch" \
  "---
agent: review
measurements:
  - id: em-001
    scorer: trace_fitness
    version: 1
" 1 "does not match filename stem" "code.yaml"

run_case "duplicate-id" \
  "---
agent: code
measurements:
  - id: em-001
    scorer: trace_fitness
    version: 1
  - id: em-001
    scorer: trace_fitness
    version: 1
" 1 "duplicate id 'em-001'"

run_case "uppercase-id" \
  "---
agent: code
measurements:
  - id: EM-001
    scorer: trace_fitness
    version: 1
" 1 "must be lowercase like em-001"

run_case "missing-version" \
  "---
agent: code
measurements:
  - id: em-001
    scorer: trace_fitness
" 1 "version must be a positive integer"

run_case "empty-dir" \
  "" 1 "no eval/measurements/*.yaml files found"

run_case "flow-style-unsupported" \
  "agent: code
measurements: [{id: em-001, scorer: trace_fitness, version: 1}]
" 1 "unsupported YAML shape"

run_case "nested-assert-unsupported" \
  "agent: code
measurements:
  - id: em-001
    scorer: trace_fitness
    version: 1
    assert:
      - path: x
" 1 "unsupported YAML shape"

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
