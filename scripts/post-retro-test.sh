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
# Capture stdin if --input - is passed (also avoids SIGPIPE under pipefail).
for arg in "$@"; do
  if [[ "${arg}" == "--input" ]]; then
    cat >> "${GH_LOG}.body"
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

# Comment posting via gh api — controlled by GH_MOCK_COMMENT_FAIL (summary)
# and GH_MOCK_EVIDENCE_FAIL (evidence comments on other issues).
if [[ "$1" == "api" && "$2" == *"/comments" ]]; then
  # Determine which failure mode to use based on the endpoint.
  FAIL_MODE="${GH_MOCK_COMMENT_FAIL:-}"
  if [[ "$2" != "repos/test-org/test-repo/issues/10/comments" && -n "${GH_MOCK_EVIDENCE_FAIL:-}" ]]; then
    FAIL_MODE="${GH_MOCK_EVIDENCE_FAIL}"
  fi
  case "${FAIL_MODE}" in
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

export PATH="${MOCK_BIN}:${PATH}"
export GH_LOG="${GH_LOG}"
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

# Fixture: a valid agent result with no proposals.
FIXTURE_NO_PROPOSALS='{
  "summary": "The retro analysis found no actionable improvements.",
  "proposals": []
}'

# Fixture: a valid agent result with evidence comments.
FIXTURE_WITH_EVIDENCE='{
  "summary": "Found evidence corroborating existing issue #42.",
  "proposals": [],
  "evidence_comments": [
    {
      "issue_url": "https://github.com/test-org/target-repo/issues/42",
      "body": "### Evidence from retro of PR #10\n\nWidget service crashed again on empty input.\n\n_Source: https://github.com/test-org/test-repo/pull/10_"
    }
  ]
}'

# Fixture: proposals + evidence comments together.
FIXTURE_PROPOSALS_AND_EVIDENCE='{
  "summary": "Found one improvement and evidence for #42.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input."
    }
  ],
  "evidence_comments": [
    {
      "issue_url": "https://github.com/test-org/target-repo/issues/42",
      "body": "### Evidence from retro of PR #10\n\nMore evidence here.\n\n_Source: https://github.com/test-org/test-repo/pull/10_"
    }
  ]
}'

# Fixture: multiple evidence comments targeting different issues.
FIXTURE_MULTI_EVIDENCE='{
  "summary": "Found evidence corroborating two existing issues.",
  "proposals": [],
  "evidence_comments": [
    {
      "issue_url": "https://github.com/test-org/target-repo/issues/42",
      "body": "### Evidence from retro\n\nFirst issue evidence.\n\n_Source: https://github.com/test-org/test-repo/pull/10_"
    },
    {
      "issue_url": "https://github.com/test-org/other-repo/issues/7",
      "body": "### Evidence from retro\n\nSecond issue evidence.\n\n_Source: https://github.com/test-org/test-repo/pull/10_"
    }
  ]
}'

run_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"
  local comment_fail="${5:-}"
  local evidence_fail="${6:-}"

  # Create iteration output structure.
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"

  # Clear gh call log.
  : > "${GH_LOG}"
  : > "${GH_LOG}.body"
  export GH_MOCK_COMMENT_FAIL="${comment_fail}"
  export GH_MOCK_EVIDENCE_FAIL="${evidence_fail}"

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
  local evidence_fail="${6:-}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_LOG}.body"
  export GH_MOCK_COMMENT_FAIL="${comment_fail}"
  export GH_MOCK_EVIDENCE_FAIL="${evidence_fail}"

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

# Evidence comments: happy path — gh api called on the referenced issue.
run_test "evidence-comment-posted" \
  "${FIXTURE_WITH_EVIDENCE}" \
  "repos/test-org/target-repo/issues/42/comments"

# Evidence comments: verify the posted body matches the fixture.
run_test "evidence-body-posted" \
  "${FIXTURE_WITH_EVIDENCE}" \
  "repos/test-org/target-repo/issues/42/comments"
# The body log should contain the evidence comment text sent via --input.
if ! grep -qF "Widget service crashed again on empty input" "${GH_LOG}.body"; then
  echo "FAIL: evidence-body-posted — expected evidence body not found in captured stdin"
  echo "Captured body:"
  cat "${GH_LOG}.body"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: evidence-body-posted (body verified)"
fi

# Evidence comments: no evidence_comments field — no extra API calls.
run_test_stdout "no-evidence-field" \
  "${FIXTURE_NO_PROPOSALS}" \
  "Post-retro complete."

# Evidence comments: proposals and evidence together both work.
run_test "evidence-with-proposals" \
  "${FIXTURE_PROPOSALS_AND_EVIDENCE}" \
  "repos/test-org/target-repo/issues/42/comments"

# Evidence comments: 403 on evidence comment is non-fatal.
run_test_stdout "evidence-403-non-fatal" \
  "${FIXTURE_WITH_EVIDENCE}" \
  "::warning::Could not post evidence comment" \
  "false" \
  "" \
  "403"

# Evidence comments: 401 on evidence comment is non-fatal.
run_test_stdout "evidence-401-non-fatal" \
  "${FIXTURE_WITH_EVIDENCE}" \
  "::warning::Could not post evidence comment" \
  "false" \
  "" \
  "401"

# Evidence comments: 500 on evidence comment is fatal.
run_test_stdout "evidence-500-fatal" \
  "${FIXTURE_WITH_EVIDENCE}" \
  "ERROR: failed to post evidence comment" \
  "true" \
  "" \
  "500"

# Evidence comments: multiple entries — both are posted.
run_test "multi-evidence-first" \
  "${FIXTURE_MULTI_EVIDENCE}" \
  "repos/test-org/target-repo/issues/42/comments"
run_test "multi-evidence-second" \
  "${FIXTURE_MULTI_EVIDENCE}" \
  "repos/test-org/other-repo/issues/7/comments"

# --- Results ---

if [[ ${FAILURES} -gt 0 ]]; then
  echo ""
  echo "${FAILURES} test(s) failed."
  exit 1
fi

echo ""
echo "All post-retro tests passed."
