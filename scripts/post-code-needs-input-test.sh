#!/usr/bin/env bash
# post-code-needs-input-test.sh — Test the needs_input early-exit path in
# post-code.sh end-to-end (real script, mocked gh).
#
# The needs_input short-circuit runs before any git/gh-branch/secret-scan
# work, so — unlike post-code-test.sh, which tests fragments in isolation —
# this file runs the real bundled/source script directly, following the
# post-triage-test.sh convention: mock `gh` on PATH, log every invocation,
# assert on the logged calls.
#
# Run from the repo root: bash scripts/post-code-needs-input-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

POST_SCRIPT="$(resolve_agent_script post-code "${SCRIPT_DIR}")"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# A plain, non-git working directory. REPO_DIR="." skips the cd/directory
# check in post-code.sh, so no real checkout is needed — the needs_input
# early-exit returns before any git command runs. Running from a directory
# that is guaranteed not to be a git repo also makes the "unaffected"
# regression case (which does proceed past the check) fail deterministically
# and without touching the real repo or network.
WORKDIR="${TMPDIR}/workdir"
mkdir -p "${WORKDIR}"

# Mock gh: record every invocation to a log file. None of the needs_input
# calls read gh's stdout, so a bare logger is sufficient here (unlike
# post-triage-test.sh's mock, which also emulates --body-file - stdin
# capture and label-listing responses that this path doesn't need).
GH_LOG="${TMPDIR}/gh-calls.log"
MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/gh" <<MOCKEOF
#!/usr/bin/env bash
echo "gh \$*" >> "${GH_LOG}"
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

REPO_FULL_NAME="owner/repo"
ISSUE_NUMBER="42"

# Runs the real post-code script against a fixture agent-result.json.
# Leaves the result in EXIT_CODE, the gh call log at ${GH_LOG}, and stdout
# at ${TMPDIR}/stdout.log for assertions.
run_post_code() {
  local fixture_json="$1"
  local fixture_dir="${TMPDIR}/fixture-input"
  rm -rf "${fixture_dir}"
  mkdir -p "${fixture_dir}"
  echo "${fixture_json}" > "${fixture_dir}/agent-result.json"

  : > "${GH_LOG}"

  EXIT_CODE=0
  (
    cd "${WORKDIR}" && \
    PATH="${MOCK_BIN}:${PATH}" \
    REPO_DIR="." \
    PUSH_TOKEN="fake-token" \
    REPO_FULL_NAME="${REPO_FULL_NAME}" \
    ISSUE_NUMBER="${ISSUE_NUMBER}" \
    FULLSEND_VALIDATED_ITERATION_DIR="${fixture_dir}" \
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || EXIT_CODE=$?
}

# Same as run_post_code, but with CODE_NEEDS_INPUT_LABEL overridden.
run_post_code_with_label() {
  local fixture_json="$1"
  local label="$2"
  local fixture_dir="${TMPDIR}/fixture-input"
  rm -rf "${fixture_dir}"
  mkdir -p "${fixture_dir}"
  echo "${fixture_json}" > "${fixture_dir}/agent-result.json"

  : > "${GH_LOG}"

  EXIT_CODE=0
  (
    cd "${WORKDIR}" && \
    PATH="${MOCK_BIN}:${PATH}" \
    REPO_DIR="." \
    PUSH_TOKEN="fake-token" \
    REPO_FULL_NAME="${REPO_FULL_NAME}" \
    ISSUE_NUMBER="${ISSUE_NUMBER}" \
    CODE_NEEDS_INPUT_LABEL="${label}" \
    FULLSEND_VALIDATED_ITERATION_DIR="${fixture_dir}" \
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || EXIT_CODE=$?
}

assert_log_pattern() {
  local test_name="$1"
  local pattern="$2"
  local expect_present="$3"  # "yes" or "no"

  if [ "${expect_present}" = "yes" ]; then
    if grep -qF -- "${pattern}" "${GH_LOG}"; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name} — expected gh call pattern '${pattern}' not found"
      echo "Actual calls:"
      cat "${GH_LOG}"
      FAILURES=$((FAILURES + 1))
    fi
  else
    if grep -qF -- "${pattern}" "${GH_LOG}"; then
      echo "FAIL: ${test_name} — expected gh call pattern '${pattern}' NOT to be found"
      echo "Actual calls:"
      cat "${GH_LOG}"
      FAILURES=$((FAILURES + 1))
    else
      echo "PASS: ${test_name}"
    fi
  fi
}

assert_exit_code() {
  local test_name="$1"
  local expected="$2"

  if [ "${EXIT_CODE}" -eq "${expected}" ]; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected exit code ${expected}, got ${EXIT_CODE}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Test cases ---

NEEDS_INPUT_TEXT="scan-secrets helper not found in sandbox image at /usr/local/bin/scan-secrets"
FIXTURE_NEEDS_INPUT="{\"target_branch\":\"main\",\"needs_input\":\"${NEEDS_INPUT_TEXT}\"}"

run_post_code "${FIXTURE_NEEDS_INPUT}"

assert_log_pattern "needs-input-skips-push-and-pr" \
  "gh pr create" "no"

assert_log_pattern "needs-input-applies-label" \
  "gh api repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels -f labels[]=fs-code-needs-input --silent" "yes"

assert_log_pattern "needs-input-removes-ready-to-code" \
  "gh api repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels/ready-to-code -X DELETE --silent" "yes"

assert_log_pattern "needs-input-posts-comment" \
  "gh issue comment ${ISSUE_NUMBER} --repo ${REPO_FULL_NAME} --body" "yes"

assert_log_pattern "needs-input-posts-comment-includes-text" \
  "${NEEDS_INPUT_TEXT}" "yes"

assert_exit_code "needs-input-exits-zero" 0

# Regression guard: a result file without needs_input must not take the
# needs_input path at all. It's fine (and expected, per the test plan) for
# the script to fail further down since WORKDIR is not a git repo — only
# assert that none of the needs_input-specific gh calls happened.
run_post_code '{"target_branch":"main"}'

assert_log_pattern "no-needs-input-field-unaffected" \
  "fs-code-needs-input" "no"

# CODE_NEEDS_INPUT_LABEL env override
run_post_code_with_label "${FIXTURE_NEEDS_INPUT}" "custom-label"

assert_log_pattern "respects-code-needs-input-label-env-override" \
  "gh api repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels -f labels[]=custom-label --silent" "yes"

assert_log_pattern "respects-code-needs-input-label-env-override-no-default-label" \
  "labels[]=fs-code-needs-input" "no"

# --- Summary ---

echo ""
if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
