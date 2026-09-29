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

run_failure_comment_test "failure-comment-workflow-permission-security-boundary" \
  "push-workflow-permission" "permission denied on workflow path" "my-org/my-repo" "12345" \
  "Security boundary" "yes"

run_failure_comment_test "failure-comment-workflow-permission-intentional" \
  "push-workflow-permission" "permission denied on workflow path" "my-org/my-repo" "12345" \
  "intentionally lacks" "yes"

run_failure_comment_test "failure-comment-workflow-permission-no-update-suggestion" \
  "push-workflow-permission" "permission denied on workflow path" "my-org/my-repo" "12345" \
  "update repo or app permissions" "no"

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

run_failure_comment_test "failure-comment-uncommitted-work-heading" \
  "uncommitted-work" "M  src/foo.go" "my-org/my-repo" "12345" \
  "killed before committing" "yes"

run_failure_comment_test "failure-comment-uncommitted-work-lists-files" \
  "uncommitted-work" "M  src/foo.go" "my-org/my-repo" "12345" \
  "src/foo.go" "yes"

run_failure_comment_test "failure-comment-uncommitted-work-not-noop" \
  "uncommitted-work" "M  src/foo.go" "my-org/my-repo" "12345" \
  "agent determined no changes needed" "no"

run_failure_comment_test "failure-comment-uncommitted-work-not-generic-completed" \
  "uncommitted-work" "M  src/foo.go" "my-org/my-repo" "12345" \
  "The code agent completed, but the post-code script failed" "no"

run_failure_comment_test "failure-comment-uncommitted-work-retry" \
  "uncommitted-work" "A  scripts/bar.sh" "my-org/my-repo" "12345" \
  "/fs-code" "yes"

run_fix_failure_comment_test "fix-failure-comment-push-rejected" \
  "push-rejected" "permission denied" "Push rejected" "yes"

run_fix_failure_comment_test "fix-failure-comment-workflow-permission" \
  "push-workflow-permission" \
  "refusing to allow a GitHub App to create or update workflow without workflows permission" \
  "Security boundary" "yes"

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

run_pem_redaction_test() {
  local test_name="$1"
  local pem_input="${2:-}"
  local pem_end

  if [ -z "${pem_input}" ]; then
    pem_input="$(printf '%s\n' \
      "$(printf '%s%s %s %s-----' '-----' 'BEGIN RSA' 'PRIVATE' 'KEY')" \
      "MIIEowIBAAKCAQEAfake" \
      "$(printf '%s%s %s %s-----' '-----' 'END RSA' 'PRIVATE' 'KEY')")"
    pem_end="MIIEowIBAAKCAQEAfake"
  else
    pem_end="MIIEowIBAAKCAQEAfake"
  fi

  local actual
  actual="$(sanitize_failure_detail "${pem_input}")"

  if echo "${actual}" | grep -qF "${pem_end}"; then
    echo "FAIL: ${test_name}"
    echo "  sanitized output still contains PEM payload"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! echo "${actual}" | grep -qF '[REDACTED PRIVATE KEY]'; then
    echo "FAIL: ${test_name}"
    echo "  expected [REDACTED PRIVATE KEY] in output"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_pem_redaction_test "sanitize-redacts-pem-block"

run_pem_redaction_test "sanitize-redacts-lowercase-pem-block" \
  "$(printf '%s\n' \
    "-----begin rsa private key-----" \
    "MIIEowIBAAKCAQEAfake" \
    "-----end rsa private key-----")"

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

run_push_token_redaction_test "sanitize-redacts-literal-push-token-glob-chars" \
  'tok*en?value' \
  'push failed: tok*en?value invalid'

run_push_token_redaction_test "sanitize-redacts-literal-push-token-backslash" \
  $'tok\\back' \
  $'push failed: tok\\back invalid'

run_report_post_failure_test() {
  local test_name="$1"
  local mock_bin="$2"

  local actual rc=0
  export PUSH_TOKEN="ghp_test"
  export GH_TOKEN=""
  export REPO_FULL_NAME="my-org/my-repo"
  export ISSUE_NUMBER="42"
  export GITHUB_RUN_ID="99"
  # shellcheck disable=SC2034
  POST_FAILURE_REPORTED=false
  set_post_failure "push-rejected" "push failed"
  actual="$(PATH="${mock_bin}:${PATH}" report_post_failure_to_issue 1 2>&1)" || rc=$?
  unset PUSH_TOKEN GH_TOKEN REPO_FULL_NAME ISSUE_NUMBER GITHUB_RUN_ID

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

export PUSH_TOKEN="ghp_test"
export REPO_FULL_NAME="my-org/my-repo"
export ISSUE_NUMBER="42"
# shellcheck disable=SC2034
POST_FAILURE_REPORTED=false
set_post_failure "push-rejected" "first"
PATH="${MOCK_BIN}:${PATH}" report_post_failure_to_issue 1 >/dev/null
call_count="$(PATH="${MOCK_BIN}:${PATH}" report_post_failure_to_issue 1 2>&1 | grep -c 'issue comment' || true)"
if [ "${call_count}" -eq 0 ]; then
  echo "PASS: post-failure-dedups-within-single-invocation"
else
  echo "FAIL: post-failure-dedups-within-single-invocation"
  echo "  expected second report_post_failure_to_issue call to be skipped"
  FAILURES=$((FAILURES + 1))
fi
unset PUSH_TOKEN REPO_FULL_NAME ISSUE_NUMBER

rm -rf "$(dirname "${MOCK_BIN}")"

# ---------------------------------------------------------------------------
# Transient retry + last-resort label (issue #1361)
# ---------------------------------------------------------------------------

run_transient_detector_test() {
  local test_name="$1"
  local sample="$2"
  local expect_transient="$3"

  if forge_is_transient_error "${sample}"; then
    if [ "${expect_transient}" = "yes" ]; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name}"
      echo "  treated as transient: ${sample}"
      FAILURES=$((FAILURES + 1))
    fi
  else
    if [ "${expect_transient}" = "no" ]; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name}"
      echo "  not treated as transient: ${sample}"
      FAILURES=$((FAILURES + 1))
    fi
  fi
}

run_transient_detector_test "transient-http-503" \
  "HTTP 503: Server Error" "yes"
run_transient_detector_test "transient-internal-server-error" \
  "GraphQL: Internal Server Error" "yes"
run_transient_detector_test "transient-deadline-exceeded" \
  "Post \"https://api.github.com/graphql\": context deadline exceeded" "yes"
run_transient_detector_test "transient-curl-503" \
  "curl: (22) The requested URL returned error: 503" "yes"
run_transient_detector_test "non-transient-422" \
  "HTTP 422: Validation Failed" "no"
run_transient_detector_test "non-transient-403-permission" \
  "HTTP 403: Resource not accessible by integration" "no"

run_comment_retry_test() {
  # shellcheck disable=SC2030,SC2031,SC2317
  local test_name="$1"
  local fail_times="$2"
  local error_msg="$3"
  local expect_attempts="$4"
  local expect_label="${5:-no}"

  local tmp mock_bin call_log rc=0 output attempts
  tmp=$(mktemp -d)
  mock_bin="${tmp}/bin"
  call_log="${tmp}/calls"
  mkdir -p "${mock_bin}"
  : > "${call_log}"

  cat > "${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALL_LOG}"
n=$(grep -c 'issue comment' "${CALL_LOG}" 2>/dev/null || true)
if printf '%s' " $*" | grep -q ' issue comment '; then
  if [ "${n}" -le "${FAIL_TIMES}" ]; then
    echo "${ERROR_MSG}" >&2
    exit 1
  fi
  echo "https://github.com/my-org/my-repo/issues/42#issuecomment-1"
  exit 0
fi
exit 0
MOCK
  chmod +x "${mock_bin}/gh"

  output=$(
    # shellcheck disable=SC2030,SC2031,SC2317
    {
      sleep() { :; }
      export PUSH_TOKEN="ghp_test"
      export GH_TOKEN=""
      export REPO_FULL_NAME="my-org/my-repo"
      export ISSUE_NUMBER="42"
      export GITHUB_RUN_ID="99"
      export FORGE_TRANSIENT_RETRY_BASE_DELAY=0
      export CALL_LOG="${call_log}"
      export FAIL_TIMES="${fail_times}"
      export ERROR_MSG="${error_msg}"
      # shellcheck disable=SC2034
      POST_FAILURE_REPORTED=false
      set_post_failure "pr-creation-failed" "create failed"
      PATH="${mock_bin}:${PATH}" report_post_failure_to_issue 1
    } 2>&1
  ) || rc=$?

  attempts=$(grep -c 'issue comment' "${call_log}" || true)

  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: ${test_name}"
    echo "  report_post_failure_to_issue exited ${rc}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${attempts}" -ne "${expect_attempts}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected ${expect_attempts} gh issue comment attempts, got ${attempts}"
    echo "  calls:"
    cat "${call_log}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${expect_label}" = "yes" ]; then
    if ! echo "${output}" | grep -q 'Failed to post error comment'; then
      echo "FAIL: ${test_name}"
      echo "  expected comment-post failure warning"
      echo "  output: ${output}"
      FAILURES=$((FAILURES + 1))
      rm -rf "${tmp}"
      return
    fi
    if ! grep -q 'code-agent-failed' "${call_log}"; then
      echo "FAIL: ${test_name}"
      echo "  expected last-resort code-agent-failed label apply"
      echo "  calls:"
      cat "${call_log}"
      echo "  output: ${output}"
      FAILURES=$((FAILURES + 1))
      rm -rf "${tmp}"
      return
    fi
    if ! echo "${output}" | grep -qF "${error_msg}"; then
      echo "FAIL: ${test_name}"
      echo "  expected real gh stderr to be logged, not swallowed"
      echo "  output: ${output}"
      FAILURES=$((FAILURES + 1))
      rm -rf "${tmp}"
      return
    fi
  else
    if echo "${output}" | grep -q 'Failed to post error comment'; then
      echo "FAIL: ${test_name}"
      echo "  expected comment post to succeed, but failure warning was emitted"
      echo "  output: ${output}"
      FAILURES=$((FAILURES + 1))
      rm -rf "${tmp}"
      return
    fi
    if grep -q 'code-agent-failed' "${call_log}"; then
      echo "FAIL: ${test_name}"
      echo "  last-resort label applied even though comment succeeded"
      FAILURES=$((FAILURES + 1))
      rm -rf "${tmp}"
      return
    fi
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

# 503 twice then success — 3 attempts, no last-resort label
run_comment_retry_test "failure-comment-retries-transient-503" \
  2 "HTTP 503: Internal Server Error" 3 no

# 503 every time — 3 attempts then last-resort label, stderr preserved
run_comment_retry_test "failure-comment-gives-up-after-3" \
  99 "HTTP 503: Internal Server Error" 3 yes

# Non-transient 422 — single attempt, then last-resort label
run_comment_retry_test "failure-comment-no-retry-on-422" \
  99 "HTTP 422: Validation Failed" 1 yes

run_pr_comment_retry_test() {
  # shellcheck disable=SC2030,SC2031,SC2317
  local test_name="$1"
  local fail_times="$2"
  local error_msg="$3"
  local expect_attempts="$4"

  local tmp mock_bin call_log rc=0 output attempts
  tmp=$(mktemp -d)
  mock_bin="${tmp}/bin"
  call_log="${tmp}/calls"
  mkdir -p "${mock_bin}"
  : > "${call_log}"

  cat > "${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALL_LOG}"
n=$(grep -c 'pr comment' "${CALL_LOG}" 2>/dev/null || true)
if printf '%s' " $*" | grep -q ' pr comment '; then
  if [ "${n}" -le "${FAIL_TIMES}" ]; then
    echo "${ERROR_MSG}" >&2
    exit 1
  fi
  echo "https://github.com/my-org/my-repo/pull/7#issuecomment-1"
  exit 0
fi
exit 0
MOCK
  chmod +x "${mock_bin}/gh"

  output=$(
    # shellcheck disable=SC2030,SC2031,SC2317
    {
      sleep() { :; }
      export PUSH_TOKEN="ghp_test"
      export GH_TOKEN=""
      export REPO_FULL_NAME="my-org/my-repo"
      export PR_NUMBER="7"
      export GITHUB_RUN_ID="99"
      export FORGE_TRANSIENT_RETRY_BASE_DELAY=0
      export CALL_LOG="${call_log}"
      export FAIL_TIMES="${fail_times}"
      export ERROR_MSG="${error_msg}"
      # shellcheck disable=SC2034
      POST_FAILURE_REPORTED=false
      set_post_failure "push-rejected" "push failed"
      PATH="${mock_bin}:${PATH}" report_post_failure_to_pr 1
    } 2>&1
  ) || rc=$?

  attempts=$(grep -c 'pr comment' "${call_log}" || true)

  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: ${test_name}"
    echo "  report_post_failure_to_pr exited ${rc}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${attempts}" -ne "${expect_attempts}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected ${expect_attempts} gh pr comment attempts, got ${attempts}"
    echo "  calls:"
    cat "${call_log}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if ! grep -q 'fix-agent-failed' "${call_log}"; then
    echo "FAIL: ${test_name}"
    echo "  expected last-resort fix-agent-failed label apply"
    echo "  calls:"
    cat "${call_log}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

run_pr_comment_retry_test "fix-failure-comment-retries-transient-503" \
  99 "HTTP 503: Internal Server Error" 3

# ---------------------------------------------------------------------------
# forge_retry_transient sanitizes failure output before logging (review on
# PR #1364, 2nd pass: preferring sanitize_failure_detail alone leaves
# parameterized workflow commands and mid-string commands like
# ::stop-commands::/::add-mask:: intact, since sanitize_comment_workflow_
# commands only strips an exact line-start "::word::" form. Composing it
# with sanitize_gha_log_output -- which strips any "::" occurrence
# regardless of position or parameters -- closes that gap. Also uses a
# token that actually matches the redaction regex ({20,} chars), unlike the
# previous placeholder literal which never matched.
# ---------------------------------------------------------------------------

run_retry_sanitizes_output_test() {
  local test_name="$1"
  local real_token="$2"

  local tmp mock_bin rc=0 output
  tmp=$(mktemp -d)
  mock_bin="${tmp}/bin"
  mkdir -p "${mock_bin}"
  cat > "${mock_bin}/gh" <<MOCK
#!/usr/bin/env bash
echo '::error file=x::HTTP 500 token=${real_token} ::stop-commands::deadbeef ::add-mask::secretvalue' >&2
exit 1
MOCK
  chmod +x "${mock_bin}/gh"

  output=$(
    {
      # shellcheck disable=SC2317
      sleep() { :; }
      PATH="${mock_bin}:${PATH}" FORGE_TRANSIENT_RETRY_ATTEMPTS=1 \
        forge_retry_transient gh whatever
    } 2>&1
  ) || rc=$?

  if [ "${rc}" -eq 0 ]; then
    echo "FAIL: ${test_name}"
    echo "  expected non-zero exit code"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if echo "${output}" | grep -q '::'; then
    echo "FAIL: ${test_name}"
    echo "  a workflow-command sequence was not stripped: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if echo "${output}" | grep -qF "${real_token}"; then
    echo "FAIL: ${test_name}"
    echo "  token was not redacted: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if ! echo "${output}" | grep -q 'HTTP 500'; then
    echo "FAIL: ${test_name}"
    echo "  diagnostic text was lost, not just sanitized: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

run_retry_sanitizes_output_test "forge-retry-sanitizes-failure-output" \
  "$(printf 'gh%s_%s' 'p' 'abcdefghijklmnopqrstuvwxyz1234')"


# ---------------------------------------------------------------------------
# _post_failure_apply_failed_label dispatch, target=pr (review on PR #1364,
# 2nd pass): forge_add_pr_label in both github-fix-ops.lib.sh and
# gitlab-fix-ops.lib.sh unconditionally swallows forge errors
# (`2>/dev/null || true` / `> /dev/null 2>/dev/null || true`) and always
# returns 0, so calling it for last-resort apply would silently report
# success during the exact outage this label exists to catch. These tests
# source the real fix-ops libs (not stubs) so forge_add_pr_label is declared
# with its actual swallowing body, then force the underlying gh/curl call to
# fail persistently with a 5xx and assert the failure still surfaces via
# "Failed to apply last-resort" rather than being absorbed by
# forge_add_pr_label's `|| true`.
# ---------------------------------------------------------------------------

run_apply_label_surfaces_failure_github_test() {
  local test_name="$1"

  local tmp mock_bin call_log rc=0 output
  tmp=$(mktemp -d)
  mock_bin="${tmp}/bin"
  call_log="${tmp}/calls"
  mkdir -p "${mock_bin}"
  : > "${call_log}"

  cat > "${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALL_LOG}"
echo "HTTP 500: Internal Server Error" >&2
exit 1
MOCK
  chmod +x "${mock_bin}/gh"

  output=$(
    # shellcheck disable=SC2030,SC2031,SC2317
    {
      sleep() { :; }
      # shellcheck disable=SC1091
      source "${SCRIPT_DIR}/lib/github-fix-ops.lib.sh"
      export CALL_LOG="${call_log}"
      export REPO_FULL_NAME="my-org/my-repo"
      export PR_NUMBER="7"
      export FORGE_TRANSIENT_RETRY_BASE_DELAY=0
      PATH="${mock_bin}:${PATH}" _post_failure_apply_failed_label "fix-agent-failed" "pr"
    } 2>&1
  ) || rc=$?

  if [ "${rc}" -eq 0 ]; then
    echo "FAIL: ${test_name}"
    echo "  expected a non-zero exit -- the persistent gh 500 should not be"
    echo "  absorbed by forge_add_pr_label's swallow-all body"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if ! echo "${output}" | grep -q 'Failed to apply last-resort'; then
    echo "FAIL: ${test_name}"
    echo "  expected the apply failure to be surfaced, not swallowed"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if ! grep -qE '^pr edit ' "${call_log}"; then
    echo "FAIL: ${test_name}"
    echo "  expected the direct 'gh pr edit' path to be used"
    echo "  calls:"
    cat "${call_log}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

run_apply_label_surfaces_failure_github_test \
  "apply-label-github-fix-agent-surfaces-persistent-failure"

run_apply_label_surfaces_failure_gitlab_test() {
  local test_name="$1"

  local tmp mock_bin call_log rc=0 output
  tmp=$(mktemp -d)
  mock_bin="${tmp}/bin"
  call_log="${tmp}/calls"
  mkdir -p "${mock_bin}"
  : > "${call_log}"

  cat > "${mock_bin}/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALL_LOG}"
echo "HTTP 500: Internal Server Error" >&2
exit 1
MOCK
  chmod +x "${mock_bin}/curl"

  output=$(
    # shellcheck disable=SC2030,SC2031,SC2317
    {
      sleep() { :; }
      # shellcheck disable=SC1091
      source "${SCRIPT_DIR}/lib/gitlab-fix-ops.lib.sh"
      export CALL_LOG="${call_log}"
      export FULLSEND_FORGE="gitlab"
      export REPO_FULL_NAME="group/project"
      export REPO_ENCODED="group%2Fproject"
      export GITLAB_HOST="gitlab.example.com"
      export CI_SERVER_HOST="gitlab.example.com"
      export GITLAB_TOKEN="test-token"
      export PR_NUMBER="7"
      export FORGE_TRANSIENT_RETRY_BASE_DELAY=0
      PATH="${mock_bin}:${PATH}" _post_failure_apply_failed_label "fix-agent-failed" "pr"
    } 2>&1
  ) || rc=$?

  if [ "${rc}" -eq 0 ]; then
    echo "FAIL: ${test_name}"
    echo "  expected a non-zero exit -- the persistent curl 500 should not be"
    echo "  absorbed by forge_add_pr_label's swallow-all body"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if ! echo "${output}" | grep -q 'Failed to apply last-resort'; then
    echo "FAIL: ${test_name}"
    echo "  expected the apply failure to be surfaced, not swallowed"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if ! grep -q 'merge_requests/7' "${call_log}"; then
    echo "FAIL: ${test_name}"
    echo "  expected the direct _gitlab_api PUT against the MR label endpoint"
    echo "  calls:"
    cat "${call_log}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

run_apply_label_surfaces_failure_gitlab_test \
  "apply-label-gitlab-fix-agent-surfaces-persistent-failure"

run_gitlab_issue_label_direct_api_test() {
  # shellcheck disable=SC2030,SC2031,SC2317
  local test_name="$1"

  local tmp call_log rc=0 output
  tmp=$(mktemp -d)
  call_log="${tmp}/calls"
  : > "${call_log}"

  output=$(
    # shellcheck disable=SC2030,SC2031,SC2317
    {
      sleep() { :; }
      _gitlab_code_api() {
        printf '%s\n' "$*" >> "${CALL_LOG}"
        if printf '%s' "$*" | grep -q '/labels '; then
          return 0
        fi
        echo "GitLab API error (HTTP 503): Service Unavailable" >&2
        return 1
      }
      export CALL_LOG="${call_log}"
      export FULLSEND_FORGE="gitlab"
      export REPO_FULL_NAME="group/project"
      export REPO_ENCODED="group%2Fproject"
      export ISSUE_NUMBER="42"
      export FORGE_TRANSIENT_RETRY_BASE_DELAY=0
      _post_failure_apply_failed_label "code-agent-failed" "issue"
    } 2>&1
  ) || rc=$?

  if [ "${rc}" -eq 0 ]; then
    echo "FAIL: ${test_name}"
    echo "  expected a non-zero exit — the stubbed issue-label API always fails"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if ! grep -q 'issues/42' "${call_log}"; then
    echo "FAIL: ${test_name}"
    echo "  expected _gitlab_code_api PUT against the issue label endpoint"
    echo "  calls:"
    cat "${call_log}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if ! echo "${output}" | grep -q 'Failed to apply last-resort'; then
    echo "FAIL: ${test_name}"
    echo "  expected the apply failure to be surfaced, not swallowed"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

run_gitlab_issue_label_direct_api_test \
  "apply-label-gitlab-issue-uses-direct-api-and-surfaces-failure"

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All post-failure-report tests passed"
