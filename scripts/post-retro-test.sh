#!/usr/bin/env bash
# post-retro-test.sh — Test post-retro.sh with fixture JSON inputs.
#
# Uses a mock gh command to capture calls without hitting GitHub.
# Run from the repo root: bash scripts/post-retro-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_SCRIPT="${SCRIPT_DIR}/post-retro.sh"
FAILURES=0

# Create a temp directory for test fixtures and mock state.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# --- Mock gh ---
# GH_MOCK_COMMENT_FAIL controls how the mock responds to the comment-posting
# gh api call:
#   "" (empty/unset)  — succeed (exit 0)
#   "403"             — fail with HTTP 403
#   "401"             — fail with HTTP 401
#   "500"             — fail with HTTP 500
#   "422"             — fail with HTTP 422
GH_LOG="${TMPDIR}/gh-calls.log"
MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
# Capture stdin if --input - is passed. Save to GH_STDIN_LOG for API calls
# so tests can inspect the request body. Fall back to /dev/null.
for arg in "$@"; do
  if [[ "${arg}" == "--input" ]]; then
    if [[ "$1" == "api" && -n "${GH_STDIN_LOG:-}" ]]; then
      cat >> "${GH_STDIN_LOG}"
    else
      cat > /dev/null
    fi
    break
  fi
done

echo "gh $*" >> "${GH_LOG}"

# Label creation calls — succeed silently (mimics --force behavior).
if [[ "$1" == "label" && "$2" == "create" ]]; then
  exit 0
fi

# Issue creation calls — return a fake issue URL.
if [[ "$1" == "issue" && "$2" == "create" ]]; then
  echo "https://github.com/test-org/target-repo/issues/99"
  exit 0
fi

# Comment posting via gh api — controlled by GH_MOCK_COMMENT_FAIL.
if [[ "$1" == "api" && "$2" == *"/comments" ]]; then
  case "${GH_MOCK_COMMENT_FAIL:-}" in
    403)
      echo "HTTP 403: Resource not accessible by integration" >&2
      exit 1
      ;;
    401)
      echo "HTTP 401: Unauthorized" >&2
      exit 1
      ;;
    500)
      echo "HTTP 500: Internal Server Error" >&2
      exit 1
      ;;
    422)
      echo "HTTP 422: Unprocessable Entity" >&2
      exit 1
      ;;
    *)
      echo '{"id": 1, "html_url": "https://github.com/test-org/test-repo/pull/10#issuecomment-1"}'
      exit 0
      ;;
  esac
fi

# Default: succeed silently.
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

# Mock jq is not needed — we use the real jq.
# Mock sed is not needed — we use the real sed.

GH_STDIN_LOG="${TMPDIR}/gh-stdin.log"

export PATH="${MOCK_BIN}:${PATH}"
export GH_LOG="${GH_LOG}"
export GH_STDIN_LOG="${GH_STDIN_LOG}"
export ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"
export GH_TOKEN="fake-token"

# Fixture: a valid agent result with one proposal.
FIXTURE_ONE_PROPOSAL='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input."
    }
  ]
}'

# Fixture: a valid agent result with an evidence-for proposal.
FIXTURE_EVIDENCE_FOR='{
  "summary": "The retro analysis found corroborating evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for #1234: review agent missed authorization check",
      "what_happened": "The review agent did not flag a missing auth check.",
      "what_could_go_better": "Authorization checks should be flagged.",
      "proposed_change": "Add auth-check detection to review prompts.",
      "validation_criteria": "Review agent flags missing auth checks."
    }
  ]
}'

# Fixture: mixed proposals — one evidence-for (filtered) and one normal (filed).
FIXTURE_MIXED='{
  "summary": "The retro analysis found two items.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for #5678: redundant review runs",
      "what_happened": "Five reviews ran on the same commit.",
      "what_could_go_better": "Dedup review triggers.",
      "proposed_change": "Check for existing review before dispatch.",
      "validation_criteria": "No duplicate reviews on same SHA."
    },
    {
      "target_repo": "test-org/target-repo",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input."
    }
  ]
}'

# Fixture: title contains "evidence" but is NOT an evidence-for proposal.
FIXTURE_FALSE_POSITIVE='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Fix evidence gathering bug",
      "what_happened": "Evidence collection crashes on empty logs.",
      "what_could_go_better": "Handle empty log files gracefully.",
      "proposed_change": "Add empty-file guard in evidence collector.",
      "validation_criteria": "No crash on empty log input."
    }
  ]
}'

# Fixture: evidence-for with uppercase title.
FIXTURE_EVIDENCE_UPPERCASE='{
  "summary": "The retro analysis found corroborating evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "EVIDENCE FOR #999: review coverage gap",
      "what_happened": "Review coverage was low.",
      "what_could_go_better": "Increase review coverage.",
      "proposed_change": "Add coverage checks.",
      "validation_criteria": "Coverage above 80%."
    }
  ]
}'

# Fixture: "Additional evidence" title variant.
FIXTURE_ADDITIONAL_EVIDENCE='{
  "summary": "The retro analysis found additional evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Additional evidence for pattern X in review agent",
      "what_happened": "Pattern X recurred.",
      "what_could_go_better": "Address pattern X.",
      "proposed_change": "Fix pattern X.",
      "validation_criteria": "Pattern X no longer appears."
    }
  ]
}'

# Fixture: "evidence for #N" appears mid-title — must NOT be rejected.
FIXTURE_MID_TITLE_EVIDENCE='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Add evidence for #1234 test failures to the report generator",
      "what_happened": "Report generator lacks test failure evidence.",
      "what_could_go_better": "Include evidence in reports.",
      "proposed_change": "Aggregate test failures into evidence section.",
      "validation_criteria": "Reports include test failure evidence."
    }
  ]
}'

# Fixture: title starts with "Evidence for" but no issue ref — must NOT be rejected.
FIXTURE_EVIDENCE_NO_ISSUEREF='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for improving review coverage across all repos",
      "what_happened": "Review coverage is inconsistent.",
      "what_could_go_better": "Standardize review coverage.",
      "proposed_change": "Add coverage checks to CI.",
      "validation_criteria": "All repos have coverage checks."
    }
  ]
}'

# Fixture: title with :: that could inject a workflow command.
FIXTURE_TITLE_DOUBLE_COLON='{
  "summary": "The retro analysis found corroborating evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for #42: ::error::injected command",
      "what_happened": "Attempted injection.",
      "what_could_go_better": "Sanitize titles.",
      "proposed_change": "Strip dangerous sequences.",
      "validation_criteria": "No injection."
    }
  ]
}'

# Fixture: title with %0A that could inject a newline in workflow commands.
FIXTURE_TITLE_PERCENT_ENCODED='{
  "summary": "The retro analysis found corroborating evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for #42: test%0A::error::injected",
      "what_happened": "Attempted percent-encoded injection.",
      "what_could_go_better": "Sanitize titles.",
      "proposed_change": "Strip percent-encoded sequences.",
      "validation_criteria": "No injection."
    }
  ]
}'

# Fixture: a valid agent result with no proposals.
FIXTURE_NO_PROPOSALS='{
  "summary": "The retro analysis found no actionable improvements.",
  "proposals": []
}'

run_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"
  local comment_fail="${5:-}"

  # Create iteration output structure.
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"

  # Clear gh call log and stdin log.
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  export GH_MOCK_COMMENT_FAIL="${comment_fail}"

  # Run the post-script.
  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
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

  if [[ -n "${expected_pattern}" ]] && ! grep -qF "${expected_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — expected gh call pattern '${expected_pattern}' not found"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_stdout() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local expect_failure="${4:-false}"
  local comment_fail="${5:-}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  export GH_MOCK_COMMENT_FAIL="${comment_fail}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    if [[ -n "${expected_stdout}" ]] && ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log"; then
      echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
      echo "Actual stdout:"
      cat "${TMPDIR}/stdout.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure)"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_no_gh_call() {
  local test_name="$1"
  local json_content="$2"
  local forbidden_pattern="$3"
  local expected_stdout="$4"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  export GH_MOCK_COMMENT_FAIL=""

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF "${forbidden_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — forbidden gh call '${forbidden_pattern}' was made"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_stdout}" ]] && ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_stdin() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdin_pattern="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  export GH_MOCK_COMMENT_FAIL=""

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdin_pattern}" "${GH_STDIN_LOG}"; then
    echo "FAIL: ${test_name} — expected stdin pattern '${expected_stdin_pattern}' not found in gh api body"
    echo "Actual stdin:"
    cat "${GH_STDIN_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_stdout_absent() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local forbidden_stdout="$4"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  export GH_MOCK_COMMENT_FAIL=""

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF "${forbidden_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — forbidden stdout pattern '${forbidden_stdout}' found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Test cases ---

# Happy path: one proposal filed, comment posted successfully.
run_test "happy-path-one-proposal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "repos/test-org/test-repo/issues/10/comments"

# Verify that the happy-path also called gh issue create.
run_test "happy-path-issue-created" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create"

# Verify that the happy-path applied the ready-for-triage label.
run_test "happy-path-triage-label" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "ready-for-triage"

# Verify that gh label create is called before gh issue create.
run_test "label-created-before-issue" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh label create ready-for-triage"

# Happy path: no proposals, comment posted successfully.
run_test "happy-path-no-proposals" \
  "${FIXTURE_NO_PROPOSALS}" \
  "repos/test-org/test-repo/issues/10/comments"

# 403 on comment posting is non-fatal — script should exit 0 with a warning.
run_test_stdout "comment-403-non-fatal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "::warning::Could not post summary comment" \
  "false" \
  "403"

# 401 on comment posting is non-fatal — script should exit 0 with a warning.
run_test_stdout "comment-401-non-fatal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "::warning::Could not post summary comment" \
  "false" \
  "401"

# 500 on comment posting remains fatal.
run_test_stdout "comment-500-fatal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "ERROR: failed to post summary comment" \
  "true" \
  "500"

# 422 on comment posting remains fatal.
run_test_stdout "comment-422-fatal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "ERROR: failed to post summary comment" \
  "true" \
  "422"

# 403 with no proposals — still non-fatal.
run_test_stdout "comment-403-no-proposals" \
  "${FIXTURE_NO_PROPOSALS}" \
  "::warning::Could not post summary comment" \
  "false" \
  "403"

# Post-retro complete should appear on successful runs.
run_test_stdout "complete-message" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Post-retro complete."

# Evidence-for gate: proposal titled "Evidence for #1234" is rejected.
run_test_no_gh_call "evidence-for-rejected" \
  "${FIXTURE_EVIDENCE_FOR}" \
  "gh issue create" \
  "::warning::proposal[0] rejected"

# Evidence-for gate: case-insensitive rejection.
run_test_no_gh_call "evidence-for-case-insensitive" \
  "${FIXTURE_EVIDENCE_UPPERCASE}" \
  "gh issue create" \
  "::warning::proposal[0] rejected"

# Evidence-for gate: "Additional evidence" variant rejected.
run_test_no_gh_call "evidence-for-additional" \
  "${FIXTURE_ADDITIONAL_EVIDENCE}" \
  "gh issue create" \
  "::warning::proposal[0] rejected"

# Evidence-for gate: "Fix evidence gathering bug" is NOT rejected.
run_test "evidence-false-positive" \
  "${FIXTURE_FALSE_POSITIVE}" \
  "gh issue create"

# Evidence-for gate: mixed proposals — evidence one filtered, normal one filed.
run_test "evidence-for-mixed-issue-created" \
  "${FIXTURE_MIXED}" \
  "gh issue create"

run_test_stdout "evidence-for-mixed" \
  "${FIXTURE_MIXED}" \
  "1 proposal(s) filtered (evidence-for pattern)"

# Evidence-for gate: "evidence for #N" mid-title is NOT rejected.
run_test "evidence-mid-title-not-rejected" \
  "${FIXTURE_MID_TITLE_EVIDENCE}" \
  "gh issue create"

# Evidence-for gate: "Evidence for <no issue ref>" is NOT rejected.
run_test "evidence-no-issueref-not-rejected" \
  "${FIXTURE_EVIDENCE_NO_ISSUEREF}" \
  "gh issue create"

# Evidence-for gate: filtered content folded into summary comment body.
run_test_stdin "evidence-for-folded-into-summary" \
  "${FIXTURE_EVIDENCE_FOR}" \
  "Evidence notes (not filed as issues)"

# Sanitization: :: in title replaced with : in warning output.
run_test_stdout_absent "sanitize-double-colon" \
  "${FIXTURE_TITLE_DOUBLE_COLON}" \
  "::warning::proposal[0] rejected" \
  "::error::injected"

# Sanitization: %0A stripped from title in warning output.
run_test_stdout_absent "sanitize-percent-encoded" \
  "${FIXTURE_TITLE_PERCENT_ENCODED}" \
  "::warning::proposal[0] rejected" \
  "%0A"

# Truncation: comment body over 65000 chars gets truncated.
BIG_SUMMARY=$(printf 'x%.0s' $(seq 1 66000))
FIXTURE_OVERSIZED=$(jq -nc --arg s "${BIG_SUMMARY}" '{summary: $s, proposals: []}')
run_test_stdin "comment-truncated-at-limit" \
  "${FIXTURE_OVERSIZED}" \
  "...(truncated)"

# Verify truncated body is under GitHub's 65536 limit.
POSTED_LEN=$(wc -c < "${GH_STDIN_LOG}")
if [[ ${POSTED_LEN} -gt 65536 ]]; then
  echo "FAIL: comment-truncated-length — posted body is ${POSTED_LEN} chars (limit 65536)"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: comment-truncated-length"
fi

# --- Results ---

if [[ ${FAILURES} -gt 0 ]]; then
  echo ""
  echo "${FAILURES} test(s) failed."
  exit 1
fi

echo ""
echo "All post-retro tests passed."
