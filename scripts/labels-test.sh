#!/usr/bin/env bash
# labels-test.sh — Tests for scripts/lib/labels.lib.sh
#
# Run from the repo root:
#   bash scripts/labels-test.sh

set -euo pipefail

if [[ "${SCRIPT_TEST_TARGET:-source}" == "bundled" ]]; then
  echo "SKIP: labels-test (lib tests skipped in bundled mode)"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILURES=0

# --- Test helpers ---

GH_CALLS_FILE=$(mktemp)
export GH_CALLS_FILE
trap 'rm -f "${GH_CALLS_FILE}"' EXIT

setup_test() {
  > "${GH_CALLS_FILE}"  # Clear the file
  export GH_EXIT_CODE=0
  export GH_STDERR=""
  export REPO_FULL_NAME="test-org/test-repo"
  unset REPO 2>/dev/null || true
}

get_gh_call() {
  local index="${1:-0}"
  sed -n "$((index + 1))p" "${GH_CALLS_FILE}"
}

get_gh_call_count() {
  wc -l < "${GH_CALLS_FILE}" | tr -d ' '
}

# Stub gh that records calls and returns configured exit/stderr.
gh() {
  echo "$*" >> "${GH_CALLS_FILE}"
  if [[ ${GH_EXIT_CODE} -ne 0 ]]; then
    echo "${GH_STDERR}" >&2
    return ${GH_EXIT_CODE}
  fi
}
export -f gh 2>/dev/null || true

run_test() {
  local test_name="$1"
  local expected_pattern="$2"
  local actual="$3"

  if [[ "${actual}" == *"${expected_pattern}"* ]] || [[ "${expected_pattern}" == "${actual}" ]]; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name}"
    echo "  expected pattern: '${expected_pattern}'"
    echo "  actual:           '${actual}'"
    FAILURES=$((FAILURES + 1))
  fi
}

# Source the lib under test (after defining gh stub).
# shellcheck source=lib/labels.lib.sh
source "${SCRIPT_DIR}/lib/labels.lib.sh"

# --- Tests ---

# Test 1: Mandatory label emits gh label create with correct args.
setup_test
forge_ensure_label "ready-for-review"
run_test "mandatory-label-creates" \
  "label create ready-for-review --repo test-org/test-repo" \
  "$(get_gh_call 0)"

# Test 2: Non-mandatory label is a no-op.
setup_test
forge_ensure_label "question"
run_test "non-mandatory-is-noop" \
  "0" \
  "$(get_gh_call_count)"

# Test 3: "already exists" error produces no warning.
setup_test
GH_EXIT_CODE=1
GH_STDERR='label with name "ready-for-review" already exists; use `--force` to update'
stderr_output=$(forge_ensure_label "ready-for-review" 2>&1 >/dev/null)
run_test "already-exists-silent" \
  "" \
  "${stderr_output}"

# Test 4: Other errors produce a warning.
setup_test
GH_EXIT_CODE=1
GH_STDERR="HTTP 403: Resource not accessible by integration"
stderr_output=$(forge_ensure_label "ready-for-review" 2>&1 >/dev/null)
run_test "other-error-warns" \
  "Warning:" \
  "${stderr_output}"

# Test 5: Defaults are applied when no description/color provided.
setup_test
forge_ensure_label "ready-to-code"
run_test "defaults-applied-description" \
  "--description" \
  "$(get_gh_call 0)"
run_test "defaults-applied-color" \
  "--color" \
  "$(get_gh_call 0)"

# Test 6: Explicit description/color overrides defaults.
setup_test
forge_ensure_label "ready-for-review" "Custom desc" "FF0000"
run_test "explicit-overrides-default" \
  "--description Custom desc --color FF0000" \
  "$(get_gh_call 0)"

# Test 7: Uses REPO when REPO_FULL_NAME is unset.
setup_test
unset REPO_FULL_NAME
export REPO="triage-org/triage-repo"
forge_ensure_label "ready-for-triage"
run_test "falls-back-to-REPO" \
  "--repo triage-org/triage-repo" \
  "$(get_gh_call 0)"

# Test 8: No --force flag in the gh call.
setup_test
forge_ensure_label "ready-for-review"
gh_call=$(get_gh_call 0)
if [[ "${gh_call}" == *"--force"* ]]; then
  echo "FAIL: no-force-flag"
  echo "  gh call contains --force: '${gh_call}'"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: no-force-flag"
fi

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
