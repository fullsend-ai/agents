#!/usr/bin/env bash
# pre-triage-test.sh — Test pre-triage.sh with the Jira tracker.
#
# Uses a mock curl command to capture calls without hitting Jira Cloud.
# Run from the repo root: bash scripts/pre-triage-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"
PRE_SCRIPT="$(resolve_agent_script pre-triage "${SCRIPT_DIR}")"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"

CURL_LOG="${TMPDIR}/curl-calls.log"

# Mock curl: record calls. pre-triage.sh no longer mutates labels (#1408),
# so a successful run should not invoke curl at all.
printf '#!/usr/bin/env bash\necho "curl $*" >> %s\nexit 0\n' "${CURL_LOG}" > "${MOCK_BIN}/curl"
chmod +x "${MOCK_BIN}/curl"

export PATH="${MOCK_BIN}:${PATH}"
export FULLSEND_TRACKER="jira"
export JIRA_USER_EMAIL="triage@example.com"
export JIRA_TOKEN="fake-jira-token"

run_test() {
  local test_name="$1"
  local issue_url="$2"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"
  local expect_no_mutation="${5:-false}"

  : > "${CURL_LOG}"
  local exit_code=0
  (ISSUE_URL="${issue_url}" bash "${PRE_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    if [[ -n "${expected_pattern}" ]] && ! grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout.log"; then
      echo "FAIL: ${test_name} — expected error pattern '${expected_pattern}' not found"
      cat "${TMPDIR}/stdout.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    if [[ "${expect_no_mutation}" == "true" ]] && [[ -s "${CURL_LOG}" ]]; then
      echo "FAIL: ${test_name} — expected no mutation but curl was called"
      cat "${CURL_LOG}"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure, got exit code ${exit_code})"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_pattern}" ]] && ! grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_pattern}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ "${expect_no_mutation}" == "true" ]] && [[ -s "${CURL_LOG}" ]]; then
    echo "FAIL: ${test_name} — expected no mutation but curl was called"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Valid Jira issue URL: parses and validates without mutating labels (#1408).
run_test "jira-valid-url-validates-target" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "Triage target validated: TESTPROJ#TESTPROJ-42" \
  "false" "true"

# Malformed Jira issue URL: fails validation, performs no mutation.
run_test "jira-malformed-url-fails" \
  "https://test.atlassian.net/not-an-issue-url" \
  "does not match expected Jira pattern" \
  "true" "true"

# Jira host outside the Cloud allowlist: fails validation, performs no mutation.
run_test "jira-disallowed-host-fails" \
  "https://jira.example.com/browse/TESTPROJ-42" \
  "is not in the allowed host list" \
  "true" "true"

# JIRA_BASE_URL with trailing slash should still match the parsed URL.
export JIRA_BASE_URL="https://test.atlassian.net/"
run_test "jira-base-url-trailing-slash-ok" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "Triage target validated: TESTPROJ#TESTPROJ-42" \
  "false" "true"
unset JIRA_BASE_URL

# More than one trailing slash must normalise too.
export JIRA_BASE_URL="https://test.atlassian.net//"
run_test "jira-base-url-multiple-trailing-slashes-ok" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "Triage target validated: TESTPROJ#TESTPROJ-42" \
  "false" "true"
unset JIRA_BASE_URL

# --- Jira credential guard tests (#876) ---
# Verify that source-time :? guards on JIRA_USER_EMAIL and JIRA_TOKEN reject
# unset and empty values before any API call is made.

unset JIRA_TOKEN
run_test "jira-missing-token-fails" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "JIRA_TOKEN must be set" \
  "true" "true"
export JIRA_TOKEN="fake-jira-token"

export JIRA_TOKEN=""
run_test "jira-empty-token-fails" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "JIRA_TOKEN must be set" \
  "true" "true"
export JIRA_TOKEN="fake-jira-token"

unset JIRA_USER_EMAIL
run_test "jira-missing-email-fails" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "JIRA_USER_EMAIL must be set" \
  "true" "true"
export JIRA_USER_EMAIL="triage@example.com"

export JIRA_USER_EMAIL=""
run_test "jira-empty-email-fails" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "JIRA_USER_EMAIL must be set" \
  "true" "true"
export JIRA_USER_EMAIL="triage@example.com"

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
