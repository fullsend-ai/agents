#!/usr/bin/env bash
# pre-triage-test.sh — Test pre-triage.sh with the Jira and GitLab trackers.
#
# Uses a mock curl command to capture calls without hitting Jira Cloud or GitLab.
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

# OAuth 2.0 client-credentials token request: the body comes on stdin.
if [[ "\${URL}" == "https://auth.atlassian.com/oauth/token" ]]; then
  cat > /dev/null
  printf '{"access_token":"minted-access-token","expires_in":3600}\n200'
  exit 0
fi

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
unset JIRA_API_URL

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

run_test "jira-valid-url-resets-completed-label" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  '"remove":"completed"'

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

# An unexpected response shape must fail loudly, not read as "no labels left".
echo 'null' > "${MOCK_LABELS_FILE}"
run_test "jira-label-verify-malformed-response-fails" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "cannot verify label state" \
  "true"
echo '[]' > "${MOCK_LABELS_FILE}"

# JIRA_BASE_URL with trailing slash should still match the parsed URL.
export JIRA_BASE_URL="https://test.atlassian.net/"
run_test "jira-base-url-trailing-slash-ok" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  '"remove":"needs-info"'
unset JIRA_BASE_URL

# More than one trailing slash must normalise too.
export JIRA_BASE_URL="https://test.atlassian.net//"
run_test "jira-base-url-multiple-trailing-slashes-ok" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  '"remove":"needs-info"'
unset JIRA_BASE_URL

# --- JIRA_API_URL routing (#1876) ---
# Unset: REST calls fall back to the site URL (older fullsend releases).
run_test "jira-api-url-unset-falls-back-to-site" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "https://test.atlassian.net/rest/api/3/issue/TESTPROJ-42"

# Set: REST calls go to the API gateway; trailing slashes are stripped so
# the request URL has no double slash.
JIRA_GATEWAY="https://api.atlassian.com/ex/jira/11111111-2222-3333-4444-555555555555"
export JIRA_API_URL="${JIRA_GATEWAY}//"
run_test "jira-api-url-routes-rest-calls" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "${JIRA_GATEWAY}/rest/api/3/issue/TESTPROJ-42"
if grep -qF "atlassian.net/rest/api/3" "${CURL_LOG}"; then
  echo "FAIL: jira-api-url-no-site-rest-calls — REST call sent to the site URL"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-api-url-no-site-rest-calls"
fi

# The credentials are sent to JIRA_API_URL, so a non-https value is refused
# before any request is made.
export JIRA_API_URL="http://api.atlassian.com/ex/jira/11111111-2222-3333-4444-555555555555"
run_test "jira-api-url-non-https-fails" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "JIRA_API_URL must start with https://" \
  "true" "true"
unset JIRA_API_URL

# --- Jira credential guard tests (#876, #1900) ---
# Verify that the source-time :? guard on JIRA_TOKEN rejects unset and empty
# values before any API call is made. JIRA_USER_EMAIL is optional: with it
# the REST calls use Basic auth, without it (unset, empty, or blank) Bearer
# auth with the service-account token.

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

echo '[]' > "${MOCK_LABELS_FILE}"
run_test "jira-email-uses-basic-auth" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "--user triage@example.com:fake-jira-token"
if grep -qF -- "--oauth2-bearer" "${CURL_LOG}"; then
  echo "FAIL: jira-email-no-bearer-auth — Bearer auth sent alongside an email"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-email-no-bearer-auth"
fi

# Unset, empty, and whitespace-only emails all mean "no email": Bearer auth,
# never an empty-user Basic header.
for email_case in unset empty blank; do
  case "${email_case}" in
    unset) unset JIRA_USER_EMAIL ;;
    empty) export JIRA_USER_EMAIL="" ;;
    blank) export JIRA_USER_EMAIL="  " ;;
  esac
  run_test "jira-email-${email_case}-uses-bearer-auth" \
    "https://test.atlassian.net/browse/TESTPROJ-42" \
    "--oauth2-bearer fake-jira-token"
  if grep -qF -- "--user" "${CURL_LOG}"; then
    echo "FAIL: jira-email-${email_case}-no-basic-auth — Basic auth sent without an email"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: jira-email-${email_case}-no-basic-auth"
  fi
done
export JIRA_USER_EMAIL="triage@example.com"

# Bearer mode uses the same JIRA_API_URL gateway path as Basic mode.
unset JIRA_USER_EMAIL
export JIRA_API_URL="https://api.atlassian.com/ex/jira/11111111-2222-3333-4444-555555555555"
run_test "jira-bearer-routes-to-api-url" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "--oauth2-bearer fake-jira-token --fail --silent --show-error --connect-timeout 10 --max-time 30 --header Content-Type: application/json --request GET ${JIRA_API_URL}/rest/api/3/issue/TESTPROJ-42"
if grep -qF "atlassian.net/rest/api/3" "${CURL_LOG}"; then
  echo "FAIL: jira-bearer-no-site-rest-calls — REST call sent to the site URL"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-bearer-no-site-rest-calls"
fi
unset JIRA_API_URL
export JIRA_USER_EMAIL="triage@example.com"

# --- OAuth 2.0 client credentials (#1926) ---
# With only the client credentials, REST calls send a minted, masked Bearer
# token to JIRA_API_URL, and the secret reaches no command line or output.
JIRA_CLIENT_SECRET_VALUE="client-secret-DO-NOT-LEAK"
export JIRA_TOKEN=""
export FULLSEND_JIRA_CLIENT_ID="client-id-1"
export FULLSEND_JIRA_CLIENT_SECRET="${JIRA_CLIENT_SECRET_VALUE}"
export JIRA_API_URL="https://api.atlassian.com/ex/jira/11111111-2222-3333-4444-555555555555"
run_test "jira-client-credentials-uses-minted-token" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "--oauth2-bearer minted-access-token --fail --silent --show-error --connect-timeout 10 --max-time 30 --header Content-Type: application/json --request GET ${JIRA_API_URL}/rest/api/3/issue/TESTPROJ-42"
if grep -qF -- "--user" "${CURL_LOG}" \
  || ! grep -qx "::add-mask::minted-access-token" "${TMPDIR}/stdout.log" \
  || grep -qF "${JIRA_CLIENT_SECRET_VALUE}" "${CURL_LOG}" "${TMPDIR}/stdout.log"; then
  echo "FAIL: jira-client-credentials-masked-and-secret-hidden"
  cat "${CURL_LOG}" "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-client-credentials-masked-and-secret-hidden"
fi

# The documented setup maps only the client variables, so JIRA_TOKEN is
# unset, not empty; the script runs under set -u.
unset JIRA_TOKEN
run_test "jira-client-credentials-token-unset" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "--request GET ${JIRA_API_URL}/rest/api/3/issue/TESTPROJ-42"
export JIRA_TOKEN=""

# A first mint inside a command substitution, with stdout redirected to a
# file, sends its mask line to stderr. When the REST call then fails, the
# error that echoes curl's stderr must not print the token.
MINT_FAIL_BIN="${TMPDIR}/bin-mint-fail"
MINT_FAIL_STATE="${TMPDIR}/mint-fail-count"
mkdir -p "${MINT_FAIL_BIN}"
cat > "${MINT_FAIL_BIN}/curl" <<MOCKEOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\${arg}" == "https://auth.atlassian.com/oauth/token" ]]; then
    cat > /dev/null
    n=0; [[ -f "${MINT_FAIL_STATE}" ]] && n="\$(cat "${MINT_FAIL_STATE}")"
    printf '%s' "\$((n + 1))" > "${MINT_FAIL_STATE}"
    if [[ "\${n}" -eq 0 ]]; then printf '{}\n401'; else printf '{"access_token":"subshell-tok-xyz","expires_in":3600}\n200'; fi
    exit 0
  fi
done
echo "curl: (7) Failed to connect" >&2
exit 7
MOCKEOF
chmod +x "${MINT_FAIL_BIN}/curl"
mint_fail_rc=0
env -u JIRA_TOKEN PATH="${MINT_FAIL_BIN}:${PATH}" JIRA_BASE_URL="https://test.atlassian.net" bash -c '
  set -euo pipefail
  SCRIPT_DIR="$1"
  source "${SCRIPT_DIR}/lib/jira-triage-ops.lib.sh"
  r="$(_jira_api_with_status GET /myself)" || true
' _ "${SCRIPT_DIR}" > "${TMPDIR}/mint-fail.out" 2> "${TMPDIR}/mint-fail.err" || mint_fail_rc=$?
if [[ ${mint_fail_rc} -ne 0 ]] || ! grep -qF "Jira API error: curl failed" "${TMPDIR}/mint-fail.err" \
  || grep -h "subshell-tok-xyz" "${TMPDIR}/mint-fail.out" "${TMPDIR}/mint-fail.err" | grep -qv '^::add-mask::'; then
  echo "FAIL: jira-client-subshell-mint-curl-failure — the token was printed outside a mask line, or no curl error was reported (rc=${mint_fail_rc})"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-client-subshell-mint-curl-failure"
fi

# Client credentials need JIRA_API_URL; JIRA_BASE_URL is no fallback.
unset JIRA_API_URL
run_test "jira-client-credentials-without-api-url-fails" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "JIRA_API_URL (the Atlassian API gateway URL) must be set" \
  "true" "true"

# A token next to client credentials, or one client variable alone, fails
# before any request, naming the variables.
export JIRA_API_URL="https://api.atlassian.com/ex/jira/11111111-2222-3333-4444-555555555555"
export JIRA_TOKEN="fake-jira-token"
run_test "jira-token-and-client-credentials-fail" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "not both" \
  "true" "true"
export JIRA_TOKEN=""
unset FULLSEND_JIRA_CLIENT_SECRET
run_test "jira-one-client-variable-fails" \
  "https://test.atlassian.net/browse/TESTPROJ-42" \
  "must be set together" \
  "true" "true"
export JIRA_TOKEN="fake-jira-token"
unset FULLSEND_JIRA_CLIENT_ID JIRA_API_URL

# --- GitLab origin validation (#1732) ---
# Self-managed GitLab on a non-default HTTPS port: the issue URL's scheme,
# host, and port must match the trusted CI server origin before any token is
# sent, and API requests must keep the port.

printf '#!/usr/bin/env bash\necho "curl $*" >> %s\n' "${CURL_LOG}" > "${MOCK_BIN}/curl"
cat >> "${MOCK_BIN}/curl" <<'CURLMOCK'
echo '{"labels":[]}'
exit 0
CURLMOCK
chmod +x "${MOCK_BIN}/curl"

export FULLSEND_TRACKER="gitlab"
export GITLAB_TOKEN="fake-gitlab-token"
export CI_SERVER_URL="https://ce.example.test:34881"
export CI_SERVER_HOST="ce.example.test"

run_test "gitlab-custom-port-matching-origin-ok" \
  "https://ce.example.test:34881/group/project/-/issues/42" \
  "https://ce.example.test:34881/api/v4/projects/group%2Fproject/issues/42"

run_test "gitlab-custom-port-mismatched-port-fails" \
  "https://ce.example.test:8443/group/project/-/issues/42" \
  "does not match CI server origin" \
  "true" "true"

run_test "gitlab-custom-port-missing-port-fails" \
  "https://ce.example.test/group/project/-/issues/42" \
  "does not match CI server origin" \
  "true" "true"

run_test "gitlab-custom-port-http-scheme-fails" \
  "http://ce.example.test:34881/group/project/-/issues/42" \
  "does not match expected GitLab pattern" \
  "true" "true"

run_test "gitlab-custom-port-different-host-fails" \
  "https://evil.example.test:34881/group/project/-/issues/42" \
  "does not match CI server origin" \
  "true" "true"

# A non-HTTPS trusted origin fails closed, even for a matching host and port.
export CI_SERVER_URL="http://ce.example.test:34881"
run_test "gitlab-non-https-ci-server-url-fails" \
  "https://ce.example.test:34881/group/project/-/issues/42" \
  "CI_SERVER_URL is not an HTTPS origin" \
  "true" "true"

# CI_SERVER_URL host must match CI_SERVER_HOST.
export CI_SERVER_URL="https://evil.example.test:34881"
run_test "gitlab-ci-server-url-host-mismatch-fails" \
  "https://evil.example.test:34881/group/project/-/issues/42" \
  "does not match CI_SERVER_HOST" \
  "true" "true"

# Standard-port regression: gitlab.com with and without CI_SERVER_URL.
export CI_SERVER_URL="https://gitlab.com"
export CI_SERVER_HOST="gitlab.com"
run_test "gitlab-com-default-port-ok" \
  "https://gitlab.com/group/project/-/issues/42" \
  "https://gitlab.com/api/v4/projects/group%2Fproject/issues/42"

run_test "gitlab-com-unexpected-port-fails" \
  "https://gitlab.com:8443/group/project/-/issues/42" \
  "does not match CI server origin" \
  "true" "true"

unset CI_SERVER_URL
run_test "gitlab-com-no-ci-server-url-ok" \
  "https://gitlab.com/group/project/-/issues/42" \
  "https://gitlab.com/api/v4/projects/group%2Fproject/issues/42"

unset CI_SERVER_HOST GITLAB_TOKEN

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
