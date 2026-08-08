#!/usr/bin/env bash
# check-rollup-result-test.sh — Tests for check-rollup-result.sh
#
# Run from the repo root: bash .github/scripts/check-rollup-result-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLUP_SCRIPT="${SCRIPT_DIR}/check-rollup-result.sh"
FAILURES=0
TESTS=0

run_rollup() {
  EVENT_NAME="$1" \
  GATE_RESULT="$2" DETECT_RESULT="$3" TESTS_RESULT="$4" \
  bash "${ROLLUP_SCRIPT}" 2>/dev/null
}

assert_pass() {
  local test_name="$1"
  shift
  TESTS=$((TESTS + 1))
  if run_rollup "$@" >/dev/null; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected exit 0"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_fail() {
  local test_name="$1"
  shift
  TESTS=$((TESTS + 1))
  if run_rollup "$@" >/dev/null; then
    echo "FAIL: ${test_name} — expected exit 1 but got 0"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name}"
  fi
}

# --- Test cases ---
#                                       event_name            gate      detect    tests

assert_pass "push, all success"         push                  skipped   success   success
assert_fail "push, tests failure"       push                  skipped   success   failure
assert_pass "merge_group, all success"  merge_group           skipped   success   success
assert_fail "merge_group, tests fail"   merge_group           skipped   success   failure

assert_pass "PRT, all success"          pull_request_target   success   success   success
assert_fail "PRT, detect skipped"       pull_request_target   success   skipped   skipped
assert_fail "PRT, all skipped"          pull_request_target   skipped   skipped   skipped

assert_fail "gate cancelled"            pull_request_target   cancelled skipped   skipped
assert_fail "detect failure"            push                  skipped   failure   skipped
assert_fail "detect cancelled"          push                  skipped   cancelled skipped
assert_fail "tests cancelled"           push                  skipped   success   cancelled

# --- Summary ---
echo ""
echo "=== ${TESTS} tests, ${FAILURES} failures ==="
if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
