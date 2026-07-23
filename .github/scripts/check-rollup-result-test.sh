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
  EVENT_NAME="$1" EVENT_ACTION="$2" LABEL_NAME="$3" \
  GATE_RESULT="$4" DETECT_RESULT="$5" TESTS_RESULT="$6" \
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
#                                       event_name            action       label              gate      detect    tests

assert_pass "push, all success"         push                  ""           ""                 skipped   success   success
assert_fail "push, tests failure"       push                  ""           ""                 skipped   success   failure
assert_pass "merge_group, all success"  merge_group           ""           ""                 skipped   success   success
assert_fail "merge_group, tests fail"   merge_group           ""           ""                 skipped   success   failure

assert_pass "PRT opened, all success"   pull_request_target   opened       ""                 success   success   success
assert_fail "PRT opened, detect skip"   pull_request_target   opened       ""                 success   skipped   skipped

assert_pass "PRT labeled ok-to-test, all success" \
                                        pull_request_target   labeled      ok-to-test         success   success   success
assert_fail "PRT labeled ok-to-test, detect skipped (unauthorized)" \
                                        pull_request_target   labeled      ok-to-test         skipped   skipped   skipped

assert_pass "PRT labeled requires-manual-review, all skipped" \
                                        pull_request_target   labeled      requires-manual-review skipped skipped skipped
assert_pass "PRT labeled arbitrary-label, all skipped" \
                                        pull_request_target   labeled      some-other-label   skipped   skipped   skipped

assert_fail "gate cancelled"            pull_request_target   opened       ""                 cancelled skipped   skipped
assert_fail "detect cancelled"          push                  ""           ""                 skipped   cancelled skipped

# --- Summary ---
echo ""
echo "=== ${TESTS} tests, ${FAILURES} failures ==="
if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
