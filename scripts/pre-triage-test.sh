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
MOCK_LABELS_FILE="${TMPDIR}/mock-labels.json"
echo '[]' > "${MOCK_LABELS_FILE}"

# Mock curl: record calls and return the labels currently on the issue.
printf '#!/usr/bin/env bash\necho "curl $*" >> %s\n' "${CURL_LOG}" > "${MOCK_BIN}/curl"
cat >> "${MOCK_BIN}/curl" <<CURLMOCK

METHOD="GET"
URL=""
for arg in "\$@"; do
  case "\${arg}" in
    --request) shift_next=method ;;
    --fail|--silent|--show-error) ;;
    --connect-timeout|--max-time|--user|--header|--data) shift_next=skip ;;
    *)
      if [[ "\${shift_next:-}" == "method" ]]; then
        METHOD="\${arg}"
        shift_next=""
      elif [[ "\${shift_next:-}" == "skip" ]]; then
        shift_next=""
      elif [[ "\${arg}" =~ ^https:// ]]; then
        URL="\${arg}"
      fi
      ;;
  esac
done

if [[ "\${URL}" =~ \\?fields=labels\$ ]] && [[ "\${METHOD}" == "GET" ]]; then
  echo '{"fields":{"labels":'"\$(cat "${MOCK_LABELS_FILE}")"'}}'
  exit 0
fi

exit 0
CURLMOCK
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

  if [[ -n "${expected_pattern}" ]] && ! grep -qF -- "${expected_pattern}" "${CURL_LOG}"; then
    echo "FAIL: ${test_name} — expected curl call pattern '${expected_pattern}' not found"
    echo "Actual curl calls:"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Valid Jira issue URL: parses and strips each triage control label.
echo '[]' > "${MOCK_LABELS_FILE}"
run_test "jira-valid-url-resets-labels" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  '"remove":"needs-info"'

run_test "jira-valid-url-resets-pr-open-label" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  '"remove":"pr-open"'

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

# A control label still present after stripping fails verification (mutation
# is attempted, but the post-strip verification GET still reports it).
echo '["needs-info"]' > "${MOCK_LABELS_FILE}"
run_test "jira-label-not-stripped-fails" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "triage labels still present after reset" \
  "true"
echo '[]' > "${MOCK_LABELS_FILE}"

# JIRA_BASE_URL with trailing slash should still match the parsed URL.
export JIRA_BASE_URL="https://test.atlassian.net/"
run_test "jira-base-url-trailing-slash-ok" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  '"remove":"needs-info"'
unset JIRA_BASE_URL

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
