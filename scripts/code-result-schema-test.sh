#!/usr/bin/env bash
# code-result-schema-test.sh — Test validate-output-schema.sh against
# schemas/code-result.schema.json fixtures.
#
# Run from the repo root:
#   bash scripts/code-result-schema-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-output-schema.sh"
SCHEMA="${SCRIPT_DIR}/../schemas/code-result.schema.json"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

run_test() {
  local test_name="$1"
  local json_content="$2"
  local expect_pass="$3"  # "true" or "false"
  local expect_output="${4:-}"  # optional: substring that must appear in stdout

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}/output"
  echo "${json_content}" > "${test_dir}/output/agent-result.json"

  local exit_code=0
  FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  local passed=true
  if [[ "${expect_pass}" == "true" && ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected PASS but got exit ${exit_code}"
    head -10 "${TMPDIR}/stdout.log"
    passed=false
  elif [[ "${expect_pass}" == "false" && ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected FAIL but got PASS"
    passed=false
  fi

  if [[ -n "${expect_output}" ]] && ! grep -qF "${expect_output}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected output to contain: ${expect_output}"
    echo "  actual output:"
    head -10 "${TMPDIR}/stdout.log"
    passed=false
  fi

  if [[ "${passed}" == "true" ]]; then
    echo "PASS: ${test_name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Regression: existing schema behavior ---

run_test "valid-target-branch-only" \
  '{"target_branch":"main"}' \
  "true"

run_test "valid-with-pr-body-and-closes-issue" \
  '{"target_branch":"main","pr_body":"desc","closes_issue":false}' \
  "true"

run_test "invalid-missing-target-branch" \
  '{"pr_body":"desc"}' \
  "false"

run_test "invalid-unknown-property" \
  '{"target_branch":"main","bogus_field":"x"}' \
  "false"

# --- needs_input field ---

run_test "valid-with-needs-input" \
  '{"target_branch":"main","needs_input":"scan-secrets helper not found"}' \
  "true"

run_test "valid-needs-input-without-target-branch" \
  '{"needs_input":"sandbox tooling broken — cannot determine target branch"}' \
  "true"

run_test "invalid-needs-input-empty-string" \
  '{"target_branch":"main","needs_input":""}' \
  "false"

TOO_LONG_INPUT="$(printf 'a%.0s' {1..4001})"
run_test "invalid-needs-input-too-long" \
  "{\"target_branch\":\"main\",\"needs_input\":\"${TOO_LONG_INPUT}\"}" \
  "false"

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
