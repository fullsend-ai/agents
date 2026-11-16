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
  CROSS_REPO="${5:-}" \
  HEAD_SHA="${HEAD_SHA:-}" \
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

# assert_output NAME PATTERN ARGS... — the roll-up output matches PATTERN.
assert_output() {
  local test_name="$1" pattern="$2"
  shift 2
  TESTS=$((TESTS + 1))
  local out
  out="$(run_rollup "$@" || true)"
  if grep -qF -- "${pattern}" <<<"${out}"; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected output containing '${pattern}', got: ${out}"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Test cases ---
#                                       event_name            gate      detect    tests     cross_repo

assert_pass "push, all success"         push                  skipped   success   success   ""
assert_fail "push, tests failure"       push                  skipped   success   failure   ""
assert_pass "merge_group, all success"  merge_group           skipped   success   success   ""
assert_fail "merge_group, tests fail"   merge_group           skipped   success   failure   ""

assert_pass "PR, all success"           pull_request          success   success   success   ""
assert_pass "PR, no agents to test"     pull_request          success   success   skipped   ""
assert_fail "PR, tests failure"         pull_request          success   success   failure   ""
assert_fail "PR, unauthorized author"   pull_request          success   skipped   skipped   ""
assert_fail "fork PR, gate skipped"     pull_request          skipped   skipped   skipped   ""

assert_pass "ok-to-test, all success"   issue_comment         skipped   success   success   ""
assert_fail "ok-to-test, tests failure" issue_comment         skipped   success   failure   ""
assert_fail "ok-to-test, detect skipped" issue_comment        skipped   skipped   skipped   ""

assert_fail "gate cancelled"            pull_request          cancelled skipped   skipped   ""
assert_fail "gate failure"              pull_request          failure   skipped   skipped   ""
assert_fail "detect failure"            push                  skipped   failure   skipped   ""
assert_fail "detect cancelled"          push                  skipped   cancelled skipped   ""
assert_fail "tests cancelled"           push                  skipped   success   cancelled ""

assert_pass "cross-repo, all success"   push                  skipped   success   success   true
assert_fail "cross-repo, tests skipped" push                  skipped   success   skipped   true
assert_pass "same-repo, tests skipped"  push                  skipped   success   skipped   ""

# pull_request_target and labeled events are no longer special: no trigger
# for them remains, and the roll-up does not call the API to mirror a verdict.
assert_pass "PRT treated as a non-PR event" pull_request_target skipped success   success   ""

# --- Fork PR failure message names /ok-to-test <sha> ---
HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
assert_output "fork PR message names /ok-to-test with the head sha" \
  "/ok-to-test 0123456789abcdef0123456789abcdef01234567" \
  pull_request skipped skipped skipped ""
HEAD_SHA=""
assert_output "fork PR message without a head sha names a placeholder" \
  "/ok-to-test <full sha of the latest push>" \
  pull_request skipped skipped skipped ""
HEAD_SHA=$'abc\n::warning::injected'
assert_output "non-sha HEAD_SHA never reaches the error line" \
  "/ok-to-test <full sha of the latest push>" \
  pull_request skipped skipped skipped ""
HEAD_SHA=""

# --- Summary ---
echo ""
echo "=== ${TESTS} tests, ${FAILURES} failures ==="
if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
