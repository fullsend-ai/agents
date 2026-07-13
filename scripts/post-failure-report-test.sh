#!/usr/bin/env bash
# post-failure-report-test.sh — Tests for scripts/lib/post-failure-report.lib.sh
#
# Run from the repo root:
#   bash scripts/post-failure-report-test.sh

set -euo pipefail

if [[ "${SCRIPT_TEST_TARGET:-source}" == "bundled" ]]; then
  echo "SKIP: post-failure-report-test (lib tests skipped in bundled mode)"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/post-failure-report.lib.sh
source "${SCRIPT_DIR}/lib/post-failure-report.lib.sh"

FAILURES=0

run_failure_comment_test() {
  local test_name="$1"
  local category="$2"
  local detail="$3"
  local repo="$4"
  local run_id="$5"
  local check_pattern="$6"
  local expect_present="$7"
  local github_repository="${8:-}"

  local actual
  export GITHUB_RUN_ID="${run_id}"
  export GITHUB_REPOSITORY="${github_repository}"
  actual="$(build_post_failure_comment "code" 1 "${category}" "${detail}" "${repo}" "/fs-code")"
  unset GITHUB_RUN_ID GITHUB_REPOSITORY

  if [ "${expect_present}" = "yes" ]; then
    if ! echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected to find: '${check_pattern}'"
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected NOT to find: '${check_pattern}'"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

run_fix_failure_comment_test() {
  local test_name="$1"
  local category="$2"
  local detail="$3"
  local check_pattern="$4"
  local expect_present="$5"

  local actual
  actual="$(build_post_failure_comment "fix" 1 "${category}" "${detail}" "my-org/my-repo" "/fs-fix")"

  if [ "${expect_present}" = "yes" ]; then
    if ! echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected to find: '${check_pattern}'"
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected NOT to find: '${check_pattern}'"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

run_failure_comment_test "failure-comment-push-rejected-category" \
  "push-rejected" "error: failed to push" "my-org/my-repo" "12345" \
  "Push rejected" "yes"

run_failure_comment_test "failure-comment-workflow-permission-category" \
  "push-workflow-permission" \
  "refusing to allow a GitHub App to create or update workflow without workflows permission" \
  "my-org/my-repo" "12345" \
  "workflows permission" "yes"

run_failure_comment_test "failure-comment-workflow-permission-environmental-note" \
  "push-workflow-permission" "permission denied on workflow path" "my-org/my-repo" "12345" \
  "Environmental limitation" "yes"

run_failure_comment_test "failure-comment-pre-commit-category" \
  "pre-commit-blocked" "trim trailing whitespace.............................Failed" \
  "my-org/my-repo" "12345" \
  "Pre-commit blocked" "yes"

run_failure_comment_test "failure-comment-secret-scan-category" \
  "secret-scan" "leaks found: 1 commit in src/config.go rule-id: aws-access-token" \
  "my-org/my-repo" "12345" \
  "Secret scan blocked" "yes"

run_failure_comment_test "failure-comment-secret-scan-no-findings" \
  "secret-scan" "leaks found: 1 commit in src/config.go" "my-org/my-repo" "12345" \
  "src/config.go" "no"

run_failure_comment_test "failure-comment-has-workflow-link" \
  "push-rejected" "push failed" "my-org/my-repo" "12345" \
  "https://github.com/my-org/my-repo/actions/runs/12345" "yes"

run_failure_comment_test "failure-comment-org-mode-uses-dispatch-repo" \
  "push-rejected" "push failed" "test-org/my-app" "12345" \
  "https://github.com/test-org/.fullsend/actions/runs/12345" "yes" \
  "test-org/.fullsend"

run_failure_comment_test "failure-comment-org-mode-not-source-repo" \
  "push-rejected" "push failed" "test-org/my-app" "12345" \
  "https://github.com/test-org/my-app/actions/runs/12345" "no" \
  "test-org/.fullsend"

run_failure_comment_test "failure-comment-non-org-mode-fallback" \
  "push-rejected" "push failed" "my-org/my-repo" "12345" \
  "https://github.com/my-org/my-repo/actions/runs/12345" "yes"

run_failure_comment_test "failure-comment-has-retry-hint" \
  "pr-creation-failed" "GraphQL error" "my-org/my-repo" "12345" \
  "/fs-code" "yes"

run_fix_failure_comment_test "fix-failure-comment-push-rejected" \
  "push-rejected" "permission denied" "Push rejected" "yes"

run_fix_failure_comment_test "fix-failure-comment-workflow-permission" \
  "push-workflow-permission" \
  "refusing to allow a GitHub App to create or update workflow without workflows permission" \
  "Environmental limitation" "yes"

run_fix_failure_comment_test "fix-failure-comment-pre-commit" \
  "pre-commit-blocked" "hook failed" "Pre-commit blocked" "yes"

run_fix_failure_comment_test "fix-failure-comment-secret-scan-no-findings" \
  "secret-scan" "finding: ghp_REDACTED in config.go" "config.go" "no"

run_fix_failure_comment_test "fix-failure-comment-secret-scan-generic-message" \
  "secret-scan" "leaks found in src/secret.env" "See workflow logs for details" "yes"

run_fix_failure_comment_test "fix-failure-comment-has-fs-fix-retry" \
  "push-rejected" "push failed" "/fs-fix" "yes"

run_fix_failure_comment_test "fix-failure-comment-has-workflow-link" \
  "push-rejected" "push failed" "/actions/runs/" "yes"

run_sanitize_test() {
  local test_name="$1"
  local input="$2"
  local must_not_contain="$3"

  local actual
  actual="$(sanitize_failure_detail "${input}")"

  if echo "${actual}" | grep -qF "${must_not_contain}"; then
    echo "FAIL: ${test_name}"
    echo "  sanitized output still contains: '${must_not_contain}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_sanitize_test "sanitize-redacts-ghp-token" \
  "auth failed with ghp_abcdefghijklmnopqrstuvwxyz1234567890" \
  "ghp_abcdefghijklmnopqrstuvwxyz1234567890"

run_sanitize_test "sanitize-redacts-ghs-token" \
  "installation token ghs_abcdefghijklmnopqrstuvwxyz1234567890" \
  "ghs_abcdefghijklmnopqrstuvwxyz1234567890"

run_sanitize_test "sanitize-redacts-access-token-url" \
  "remote: https://x-access-token:ghp_secret@github.com/org/repo.git" \
  "ghp_secret"

run_sanitize_test "sanitize-strips-gha-workflow-commands" \
  "$(printf '%s\n' '::warning::injected' 'line two')" \
  "::warning::"

run_sanitize_gha_log_test() {
  local test_name="$1"
  local input="$2"
  local must_not_contain="$3"

  local actual
  actual="$(sanitize_gha_log_output "${input}")"

  if echo "${actual}" | grep -qF "${must_not_contain}"; then
    echo "FAIL: ${test_name}"
    echo "  sanitized output still contains: '${must_not_contain}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_sanitize_gha_log_test "sanitize-gha-log-strips-workflow-commands" \
  $'::error::boom' \
  "::error::"

run_categorize_push_test() {
  local test_name="$1"
  local push_output="$2"
  local expected="$3"

  local actual
  actual="$(categorize_push_failure "${push_output}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_categorize_push_test "categorize-workflow-permission" \
  "refusing to allow a GitHub App to create or update workflow without workflows permission" \
  "push-workflow-permission"

run_categorize_push_test "categorize-generic-push-rejected" \
  "error: failed to push some refs: non-fast-forward" \
  "push-rejected"

run_categorize_push_test "categorize-unexpected-push-failed" \
  "fatal: repository 'org/missing' not found" \
  "push-failed"

run_preserve_scoped_name_test() {
  local test_name="$1"
  local input="$2"
  local must_contain="$3"

  local actual
  actual="$(sanitize_failure_detail "${input}")"

  if ! echo "${actual}" | grep -qF "${must_contain}"; then
    echo "FAIL: ${test_name}"
    echo "  expected to preserve: '${must_contain}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_preserve_scoped_name_test "sanitize-preserves-scoped-names" \
  "error: no member named 'foo' in namespace std::string" \
  "std::string"

run_sanitize_test "sanitize-redacts-bearer-token" \
  "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig" \
  "eyJhbGciOiJIUzI1NiJ9"

run_sanitize_test "sanitize-redacts-pem-block" \
  $'-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAfake\n-----END RSA PRIVATE KEY-----' \
  "MIIEowIBAAKCAQEAfake"

run_push_token_redaction_test() {
  local test_name="$1"
  local token="$2"
  local input="$3"

  local actual
  export PUSH_TOKEN="${token}"
  actual="$(sanitize_failure_detail "${input}")"
  unset PUSH_TOKEN

  if echo "${actual}" | grep -qF "${token}"; then
    echo "FAIL: ${test_name}"
    echo "  sanitized output still contains literal PUSH_TOKEN"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_push_token_redaction_test "sanitize-redacts-literal-push-token" \
  "test-secret-token-value-12345" \
  "push failed: auth test-secret-token-value-12345 invalid"

run_report_post_failure_test() {
  local test_name="$1"
  local mock_bin="$2"

  local actual rc=0
  export PUSH_TOKEN="ghp_test"
  export GH_TOKEN=""
  export REPO_FULL_NAME="my-org/my-repo"
  export ISSUE_NUMBER="42"
  export GITHUB_RUN_ID="99"
  POST_FAILURE_REPORTED=false
  set_post_failure "push-rejected" "push failed"
  actual="$(PATH="${mock_bin}:${PATH}" report_post_failure_to_issue 1 2>&1)" || rc=$?
  unset PUSH_TOKEN GH_TOKEN REPO_FULL_NAME ISSUE_NUMBER GITHUB_RUN_ID
  POST_FAILURE_REPORTED=false
  POST_FAILURE_CATEGORY=""
  POST_FAILURE_DETAIL=""

  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: ${test_name}"
    echo "  report_post_failure_to_issue exited ${rc}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! printf '%s' "${actual}" | /usr/bin/grep -q 'issue comment'; then
    echo "FAIL: ${test_name}"
    echo "  expected gh issue comment invocation"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

MOCK_BIN="$(mktemp -d)/bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "gh $*"
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/gh"
run_report_post_failure_test "report-post-failure-invokes-gh-issue-comment" "${MOCK_BIN}"
rm -rf "$(dirname "${MOCK_BIN}")"

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All post-failure-report tests passed"
