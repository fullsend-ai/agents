#!/usr/bin/env bash
# pre-review-test.sh — Test pre-review.sh author-skip and input-validation logic.
#
# Uses a mock gh command to capture calls without hitting GitHub.
# Run from the repo root: bash scripts/pre-review-test.sh

set -euo pipefail

FAILURES=0

# Create a temp directory for mock state.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# --- Mock builder ---

# build_mock creates a mock gh binary that returns preconfigured responses.
# Arguments:
#   $1 — PR state to return for "gh pr view ... --json state" (e.g. OPEN, MERGED)
#   $2 — PR author login to return for "gh pr view ... --json author"
build_mock() {
  local pr_state="$1"
  local pr_author="$2"
  local mock_bin="${TMPDIR}/bin"
  local gh_log="${TMPDIR}/gh-calls.log"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"
  : > "${gh_log}"

  # Write mock data files for the gh mock to read.
  printf '%s' "${pr_state}" > "${TMPDIR}/pr-state.txt"
  printf '%s' "${pr_author}" > "${TMPDIR}/pr-author.txt"

  cat > "${mock_bin}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
CALL_LOG="LOGFILE_PLACEHOLDER"
DATA_DIR="DATADIR_PLACEHOLDER"

echo "gh $*" >> "${CALL_LOG}"

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  # Determine which --json field was requested and find --jq expression.
  JSON_FIELD=""
  JQ_EXPR=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) JSON_FIELD="$2"; shift 2 ;;
      --jq)  JQ_EXPR="$2"; shift 2 ;;
      *)     shift ;;
    esac
  done

  # Build the appropriate JSON response.
  PR_STATE="$(cat "${DATA_DIR}/pr-state.txt")"
  PR_AUTHOR="$(cat "${DATA_DIR}/pr-author.txt")"

  case "${JSON_FIELD}" in
    state)
      RESPONSE="{\"state\":\"${PR_STATE}\"}"
      ;;
    author)
      RESPONSE="{\"author\":{\"login\":\"${PR_AUTHOR}\"}}"
      ;;
    *)
      RESPONSE="{}"
      ;;
  esac

  if [[ -n "${JQ_EXPR}" ]]; then
    echo "${RESPONSE}" | jq -r "${JQ_EXPR}"
  else
    echo "${RESPONSE}"
  fi
  exit 0
elif [[ "$1" == "issue" && "$2" == "comment" ]]; then
  cat > /dev/null
  exit 0
fi
MOCKEOF

  # Patch placeholders with actual paths.
  local escaped_log="${gh_log//\//\\/}"
  local escaped_dir="${TMPDIR//\//\\/}"
  perl -pi -e "s/LOGFILE_PLACEHOLDER/${escaped_log}/g" "${mock_bin}/gh"
  perl -pi -e "s/DATADIR_PLACEHOLDER/${escaped_dir}/g" "${mock_bin}/gh"

  chmod +x "${mock_bin}/gh"
  echo "${mock_bin}"
}

# --- Test helpers ---

run_test_stdout() {
  local test_name="$1"
  local pr_state="$2"
  local pr_author="$3"
  local expected_stdout="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_mock "${pr_state}" "${pr_author}")"

  local env_cmd=(
    env
    PATH="${mock_bin}:${PATH}"
    PR_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    PR_URL="https://github.com/test-org/test-repo/pull/42"
    FULLSEND_FORGE="github"
    REVIEW_TOKEN="fake-token"
    GH_TOKEN="fake-token"
  )

  # Add extra env vars if provided.
  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${SCRIPT_DIR}/pre-review.sh" \
    > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Check that gh calls contain a specific pattern.
run_test_gh_call() {
  local test_name="$1"
  local pr_state="$2"
  local pr_author="$3"
  local expected_pattern="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_mock "${pr_state}" "${pr_author}")"
  local gh_log="${TMPDIR}/gh-calls.log"

  local env_cmd=(
    env
    PATH="${mock_bin}:${PATH}"
    PR_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    PR_URL="https://github.com/test-org/test-repo/pull/42"
    FULLSEND_FORGE="github"
    REVIEW_TOKEN="fake-token"
    GH_TOKEN="fake-token"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${SCRIPT_DIR}/pre-review.sh" \
    > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_pattern}" "${gh_log}" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected gh call pattern '${expected_pattern}' not found"
    echo "Actual calls:"
    cat "${gh_log}" 2>/dev/null || echo "(no calls)"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Check that gh calls do NOT contain a specific pattern.
run_test_no_gh_call() {
  local test_name="$1"
  local pr_state="$2"
  local pr_author="$3"
  local forbidden_pattern="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_mock "${pr_state}" "${pr_author}")"
  local gh_log="${TMPDIR}/gh-calls.log"

  local env_cmd=(
    env
    PATH="${mock_bin}:${PATH}"
    PR_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    PR_URL="https://github.com/test-org/test-repo/pull/42"
    FULLSEND_FORGE="github"
    REVIEW_TOKEN="fake-token"
    GH_TOKEN="fake-token"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${SCRIPT_DIR}/pre-review.sh" \
    > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF "${forbidden_pattern}" "${gh_log}" 2>/dev/null; then
    echo "FAIL: ${test_name} — forbidden gh call pattern '${forbidden_pattern}' was found"
    echo "Actual calls:"
    cat "${gh_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Test cases ---

# 1. Author in skip list → exit 0, skip notice
run_test_stdout "skip-renovate-bot" \
  "OPEN" "app/renovate" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate,app/dependabot"

# 2. Different bot in skip list → exit 0, skip notice
run_test_stdout "skip-dependabot" \
  "OPEN" "app/dependabot" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate,app/dependabot"

# 3. Author NOT in skip list → review proceeds
run_test_stdout "no-skip-human-author" \
  "OPEN" "some-human" \
  "proceeding with review agent" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# 4. REVIEW_SKIP_AUTHORS unset → no skip, review proceeds for any author
run_test_stdout "unset-skip-authors-proceeds" \
  "OPEN" "app/renovate" \
  "proceeding with review agent" \
  0

# 5. REVIEW_SKIP_AUTHORS empty → no skip, review proceeds
run_test_stdout "empty-skip-authors-proceeds" \
  "OPEN" "app/renovate" \
  "proceeding with review agent" \
  0 \
  "REVIEW_SKIP_AUTHORS="

# 6. Custom bot name in skip list → exit 0
run_test_stdout "skip-custom-bot" \
  "OPEN" "custom-bot" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=custom-bot"

# 7. Whitespace around entries → still matches after trimming
run_test_stdout "skip-with-whitespace" \
  "OPEN" "app/renovate" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS= app/renovate , app/dependabot "

# 8. Skip posts a comment
run_test_gh_call "skip-posts-comment" \
  "OPEN" "app/renovate" \
  "gh issue comment 42 --repo test-org/test-repo --body-file -" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# 9. Non-matching author does not trigger author fetch for comment
run_test_stdout "no-skip-different-author" \
  "OPEN" "other-user" \
  "proceeding with review agent" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate,app/dependabot"

# 10. PR state check still works — merged PR skips before author check
run_test_stdout "merged-pr-skips-before-author-check" \
  "MERGED" "app/renovate" \
  "skipping review" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# 11. Single author in skip list works
run_test_stdout "single-author-skip-list" \
  "OPEN" "app/dependabot" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/dependabot"

# 12. Case-insensitive matching — GitHub usernames are case-insensitive
run_test_stdout "case-insensitive-skip" \
  "OPEN" "App/Renovate" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# ---------------------------------------------------------------------------
# GitLab forge pre-review tests
# ---------------------------------------------------------------------------

build_gitlab_mock() {
  local mr_state="$1"
  local mr_author="$2"
  local mock_bin="${TMPDIR}/bin-gitlab"
  local call_log="${TMPDIR}/curl-calls.log"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"
  : > "${call_log}"

  printf '%s' "${mr_state}" > "${TMPDIR}/mr-state.txt"
  printf '%s' "${mr_author}" > "${TMPDIR}/mr-author.txt"

  cat > "${mock_bin}/curl" <<MOCKEOF
#!/usr/bin/env bash
CALL_LOG="${call_log}"
echo "curl \$*" >> "\${CALL_LOG}"

URL=""
METHOD="GET"
PREV=""
for arg in "\$@"; do
  case "\${arg}" in
    https://*) URL="\${arg}" ;;
  esac
  if [[ "\${PREV}" == "--request" ]] || [[ "\${PREV}" == "-X" ]]; then
    METHOD="\${arg}"
  fi
  PREV="\${arg}"
done

# POST /notes → success (skip comment)
if [[ "\${METHOD}" == "POST" ]]; then
  echo '{"id":1}'
  exit 0
fi

# GET /merge_requests/:iid → MR metadata
if [[ "\${URL}" == *"/merge_requests/"* ]]; then
  MR_STATE=\$(cat "${TMPDIR}/mr-state.txt")
  MR_AUTHOR=\$(cat "${TMPDIR}/mr-author.txt")
  echo "{\"state\":\"\${MR_STATE}\",\"draft\":false,\"author\":{\"username\":\"\${MR_AUTHOR}\"},\"iid\":42}"
  exit 0
fi

exit 0
MOCKEOF

  chmod +x "${mock_bin}/curl"
  echo "${mock_bin}"
}

run_gitlab_test_stdout() {
  local test_name="$1"
  local mr_state="$2"
  local mr_author="$3"
  local expected_stdout="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_gitlab_mock "${mr_state}" "${mr_author}")"

  local env_cmd=(
    env
    PATH="${mock_bin}:${PATH}"
    PR_NUMBER="42"
    REPO_FULL_NAME="test-group/test-project"
    PR_URL="https://gitlab.com/test-group/test-project/-/merge_requests/42"
    FULLSEND_FORGE="gitlab"
    REVIEW_TOKEN="fake-gitlab-token"
    CI_SERVER_HOST="gitlab.com"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${SCRIPT_DIR}/pre-review.sh" \
    > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# GitLab: open MR proceeds with review
run_gitlab_test_stdout "gitlab-open-mr-proceeds" \
  "opened" "some-user" \
  "proceeding with review agent" \
  0

# GitLab: merged MR skips review
run_gitlab_test_stdout "gitlab-merged-mr-skips" \
  "merged" "some-user" \
  "skipping review" \
  0

# GitLab: author in skip list → skip
run_gitlab_test_stdout "gitlab-skip-bot-author" \
  "opened" "app/renovate" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# GitLab: author NOT in skip list → proceed
run_gitlab_test_stdout "gitlab-no-skip-human" \
  "opened" "some-human" \
  "proceeding with review agent" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# GitLab: invalid URL pattern rejected
run_gitlab_test_stdout "gitlab-invalid-url-rejected" \
  "opened" "some-user" \
  "ERROR: PR_URL does not match expected GitLab MR pattern" \
  1 \
  "PR_URL=https://gitlab.com/group/project/pull/42"

# GitLab: disallowed host rejected
run_gitlab_test_stdout "gitlab-disallowed-host-rejected" \
  "opened" "some-user" \
  "ERROR: GitLab host" \
  1 \
  "PR_URL=https://gitlab.evil.com/group/project/-/merge_requests/42"

# GitLab: no token → skip state check, proceed
run_gitlab_test_stdout "gitlab-no-token-proceeds" \
  "opened" "some-user" \
  "No token available" \
  0 \
  "REVIEW_TOKEN="

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
