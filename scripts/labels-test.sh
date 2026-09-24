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

FORGE_CALLS_FILE=$(mktemp)
export FORGE_CALLS_FILE
trap 'rm -f "${FORGE_CALLS_FILE}"' EXIT

setup_test() {
  true > "${FORGE_CALLS_FILE}"
}

get_forge_call() {
  local index="${1:-0}"
  sed -n "$((index + 1))p" "${FORGE_CALLS_FILE}"
}

get_forge_call_count() {
  wc -l < "${FORGE_CALLS_FILE}" | tr -d ' '
}

# Stub forge_create_label that records calls.
forge_create_label() {
  echo "$*" >> "${FORGE_CALLS_FILE}"
}
export -f forge_create_label 2>/dev/null || true

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

# Source the lib under test (after defining forge_create_label stub).
# shellcheck source=lib/labels.lib.sh
source "${SCRIPT_DIR}/lib/labels.lib.sh"

# --- Tests ---

# Test 1: Mandatory label delegates to forge_create_label with correct args.
setup_test
forge_ensure_label "ready-for-review"
run_test "mandatory-label-creates" \
  "ready-for-review Triggers review agent dispatch 0E8A16" \
  "$(get_forge_call 0)"

# Test 2: Non-mandatory label is a no-op.
setup_test
forge_ensure_label "question"
run_test "non-mandatory-is-noop" \
  "0" \
  "$(get_forge_call_count)"

# Test 3: Defaults are applied when no description/color provided.
setup_test
forge_ensure_label "ready-to-code"
run_test "defaults-applied-description" \
  "Triggers code agent dispatch" \
  "$(get_forge_call 0)"
run_test "defaults-applied-color" \
  "0E8A16" \
  "$(get_forge_call 0)"

# Test 4: Explicit description/color overrides defaults.
setup_test
forge_ensure_label "ready-for-review" "Custom desc" "FF0000"
run_test "explicit-overrides-default" \
  "ready-for-review Custom desc FF0000" \
  "$(get_forge_call 0)"

# ---------------------------------------------------------------------------
# forge_add_label tests (github-code-ops.lib.sh)
# ---------------------------------------------------------------------------

# Build a mock gh binary that logs every invocation and exits 0 by default.
MOCK_BIN=$(mktemp -d)
GH_CALL_LOG=$(mktemp)
GHA_WARNINGS_LOG=$(mktemp)
trap 'rm -rf "${MOCK_BIN}" "${GH_CALL_LOG}" "${GHA_WARNINGS_LOG}" "${FORGE_CALLS_FILE}"' EXIT

cat > "${MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "$*" >> "GH_LOG_PLACEHOLDER"
exit "${MOCK_GH_EXIT:-0}"
MOCKEOF
perl -pi -e "s|GH_LOG_PLACEHOLDER|${GH_CALL_LOG}|g" "${MOCK_BIN}/gh"
chmod +x "${MOCK_BIN}/gh"
export PATH="${MOCK_BIN}:${PATH}"

# Stub gha_echo to capture warnings.
gha_echo() { echo "$*" >> "${GHA_WARNINGS_LOG}"; }
export -f gha_echo 2>/dev/null || true

# Source the lib under test.
export GITHUB_CODE_OPS_SH_LOADED=""
export REPO_FULL_NAME="test-org/test-repo"
export ISSUE_NUMBER="42"
# shellcheck source=lib/github-code-ops.lib.sh
source "${SCRIPT_DIR}/lib/github-code-ops.lib.sh"

# Test 5: PR target calls gh api with correct endpoint and field encoding.
true > "${GH_CALL_LOG}"
forge_add_label "ready-for-review" "pr" "123"
run_test "add-label-pr-uses-gh-api" \
  "api repos/test-org/test-repo/issues/123/labels -f labels[]=ready-for-review --silent" \
  "$(cat "${GH_CALL_LOG}")"

# Test 6: Issue target (default) calls gh api with ISSUE_NUMBER.
true > "${GH_CALL_LOG}"
forge_add_label "pr-open"
run_test "add-label-issue-uses-gh-api" \
  "api repos/test-org/test-repo/issues/42/labels -f labels[]=pr-open --silent" \
  "$(cat "${GH_CALL_LOG}")"

# Test 7: PR target logs gha_echo warning on gh failure.
true > "${GH_CALL_LOG}"
true > "${GHA_WARNINGS_LOG}"
MOCK_GH_EXIT=1 forge_add_label "ready-for-review" "pr" "456"
run_test "add-label-pr-warns-on-failure" \
  "warning Failed to apply ready-for-review label to PR #456" \
  "$(cat "${GHA_WARNINGS_LOG}")"

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
