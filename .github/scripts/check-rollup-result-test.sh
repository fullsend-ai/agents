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
  bash "${ROLLUP_SCRIPT}" 2>/dev/null
}

# Runs the roll-up on a pull_request_target `labeled` event with a stub `gh`
# on PATH that reports $1 as the previous conclusion for this check name on
# this commit ("" = no previous run at all).
run_rollup_labeled() {
  local prior="$1"
  local label="${2:-ready-for-review}"
  local stubdir
  stubdir="$(mktemp -d)"
  cat > "${stubdir}/gh" <<STUB
#!/bin/sh
printf '%s' "${prior}"
STUB
  chmod +x "${stubdir}/gh"
  PATH="${stubdir}:${PATH}" \
  EVENT_NAME="pull_request_target" EVENT_ACTION="labeled" LABEL_NAME="${label}" \
  HEAD_SHA="deadbeef" GITHUB_REPOSITORY="fullsend-ai/agents" GITHUB_RUN_ID="1" \
  GATE_RESULT="skipped" DETECT_RESULT="skipped" TESTS_RESULT="skipped" \
  CROSS_REPO="false" \
  bash "${ROLLUP_SCRIPT}" 2>/dev/null
  local rc=$?
  rm -rf "${stubdir}"
  return $rc
}

assert_labeled_pass() {
  TESTS=$((TESTS + 1))
  if run_rollup_labeled "$2" "${3:-}" >/dev/null; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — expected exit 0"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_labeled_fail() {
  TESTS=$((TESTS + 1))
  if run_rollup_labeled "$2" "${3:-}" >/dev/null; then
    echo "FAIL: $1 — expected exit 1"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: $1"
  fi
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
#                                       event_name            gate      detect    tests     cross_repo

assert_pass "push, all success"         push                  skipped   success   success   ""
assert_fail "push, tests failure"       push                  skipped   success   failure   ""
assert_pass "merge_group, all success"  merge_group           skipped   success   success   ""
assert_fail "merge_group, tests fail"   merge_group           skipped   success   failure   ""

assert_pass "PRT, all success"          pull_request_target   success   success   success   ""
assert_fail "PRT, detect skipped"       pull_request_target   success   skipped   skipped   ""
assert_fail "PRT, all skipped"          pull_request_target   skipped   skipped   skipped   ""

assert_fail "gate cancelled"            pull_request_target   cancelled skipped   skipped   ""
assert_fail "detect failure"            push                  skipped   failure   skipped   ""
assert_fail "detect cancelled"          push                  skipped   cancelled skipped   ""
assert_fail "tests cancelled"           push                  skipped   success   cancelled ""

assert_pass "cross-repo, all success"   push                  skipped   success   success   true
assert_fail "cross-repo, tests skipped" push                  skipped   success   skipped   true
assert_pass "same-repo, tests skipped"  push                  skipped   success   skipped   ""

# --- Summary ---
echo ""
# --- label events carry no verdict: mirror the previous one (#954) ---------
# A labeled event for anything but ok-to-test skips the gate by design. The
# roll-up must not assert a fresh verdict, because whatever it reports
# supersedes the previous check run of the same name on this commit.
assert_labeled_pass "labeled: mirrors a previous success" "success"
assert_labeled_fail "labeled: does not launder a previous failure" "failure"
assert_labeled_fail "labeled: does not launder a previous cancellation" "cancelled"
assert_labeled_fail "labeled: fails closed when there is no previous verdict" ""
# ok-to-test is the one label that authorises a real run, so it must fall
# through to the normal rules rather than mirroring anything. Drive this
# through run_rollup_labeled so the mirror block is actually entered and
# declines: a stubbed prior "success" must NOT be mirrored here.
assert_labeled_fail "labeled ok-to-test does not mirror, it runs the normal rules" \
  "success" "ok-to-test"

echo "=== ${TESTS} tests, ${FAILURES} failures ==="
if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
