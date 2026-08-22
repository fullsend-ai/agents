#!/usr/bin/env bash
# post-fix-test.sh — Test the push retry logic from post-fix.sh.
#
# Extracts and tests the push-retry decision logic in isolation using shell
# functions. This avoids needing a full git repo or GitHub API access.
#
# Run from the repo root:
#   bash scripts/post-fix-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

FAILURES=0

POST_SCRIPT="$(resolve_agent_script post-fix "${SCRIPT_DIR}")"
if ! grep -q 'gha_echo' "${POST_SCRIPT}" || ! grep -q 'post_fail_to_pr' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-failure-reporting"
  echo "  ${POST_SCRIPT} missing gha_echo or post_fail_to_pr"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-failure-reporting"
fi

if ! grep -q 'install_gitleaks' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-gitleaks-install"
  echo "  ${POST_SCRIPT} missing install_gitleaks"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-gitleaks-install"
fi

# ---------------------------------------------------------------------------
# Test helper — reimplements the push retry logic from post-fix.sh section 5.
# Given a push exit code and output, returns the action.
# ---------------------------------------------------------------------------
decide_push_retry() {
  local push_rc="$1"
  local push_output="$2"

  if [ "${push_rc}" -eq 0 ]; then
    echo "success"
    return 0
  fi

  if echo "${push_output}" | grep -qi "non-fast-forward\|rejected\|fetch first"; then
    echo "retry:force-with-lease"
    return 0
  fi

  echo "fail:unexpected-error"
  return 0
}

run_push_retry_test() {
  local test_name="$1"
  local push_rc="$2"
  local push_output="$3"
  local expected_prefix="$4"

  local actual
  actual="$(decide_push_retry "${push_rc}" "${push_output}")"

  if [[ "${actual}" != ${expected_prefix}* ]]; then
    echo "FAIL: ${test_name}"
    echo "  push_rc:         '${push_rc}'"
    echo "  push_output:     '${push_output}'"
    echo "  expected prefix: '${expected_prefix}'"
    echo "  actual:          '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Push retry test cases ---

# Successful push → no retry needed
run_push_retry_test "push-success" \
  "0" "Everything up-to-date" "success"

# Non-fast-forward error → retry with --force-with-lease
run_push_retry_test "push-non-fast-forward" \
  "1" "error: failed to push some refs: non-fast-forward" "retry:force-with-lease"

# Rejected error → retry with --force-with-lease
run_push_retry_test "push-rejected" \
  "1" "! [rejected] agent/42 -> agent/42 (fetch first)" "retry:force-with-lease"

# Unknown error → fail
run_push_retry_test "push-unexpected-error" \
  "1" "fatal: repository not found" "fail:unexpected-error"

# ---------------------------------------------------------------------------
# Test helper — reimplements the pre-commit auto-fix retry decision logic
# from post-fix.sh section 3. Given a pre-commit exit code and whether
# unstaged changes exist, returns the action the script would take.
# ---------------------------------------------------------------------------
decide_precommit_retry() {
  local precommit_rc="$1"          # 0 = passed, 1 = failed
  local has_unstaged="$2"          # "yes" or "no"
  local retry_precommit_rc="$3"    # 0 = passed on retry, 1 = still fails (ignored if no retry)
  local retry_has_unstaged="${4:-no}"  # "yes" if retry left unstaged changes

  if [ "${precommit_rc}" -eq 0 ]; then
    echo "pass:clean"
    return 0
  fi

  # Pre-commit failed — check for auto-fixed files
  if [ "${has_unstaged}" = "yes" ]; then
    if [ "${retry_precommit_rc}" -eq 0 ]; then
      if [ "${retry_has_unstaged}" = "yes" ]; then
        echo "blocked:retry-left-unstaged"
      else
        echo "pass:auto-fixed"
      fi
    else
      echo "blocked:retry-failed"
    fi
  else
    echo "blocked:no-auto-fix"
  fi
}

run_precommit_retry_test() {
  local test_name="$1"
  local precommit_rc="$2"
  local has_unstaged="$3"
  local retry_precommit_rc="$4"
  local expected="$5"
  local retry_has_unstaged="${6:-no}"

  local actual
  actual="$(decide_precommit_retry "${precommit_rc}" "${has_unstaged}" "${retry_precommit_rc}" "${retry_has_unstaged}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  precommit_rc:         '${precommit_rc}'"
    echo "  has_unstaged:         '${has_unstaged}'"
    echo "  retry_precommit_rc:   '${retry_precommit_rc}'"
    echo "  retry_has_unstaged:   '${retry_has_unstaged}'"
    echo "  expected:             '${expected}'"
    echo "  actual:               '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Pre-commit auto-fix retry test cases ---

# Pre-commit passes on first run → no retry needed
run_precommit_retry_test "precommit-passes-first-run" \
  "0" "no" "0" "pass:clean"

# Pre-commit fails, hooks auto-fixed files, retry succeeds
run_precommit_retry_test "precommit-auto-fix-retry-succeeds" \
  "1" "yes" "0" "pass:auto-fixed"

# Pre-commit fails, hooks auto-fixed files, retry still fails
run_precommit_retry_test "precommit-auto-fix-retry-fails" \
  "1" "yes" "1" "blocked:retry-failed"

# Pre-commit fails, no unstaged changes (genuine failure)
run_precommit_retry_test "precommit-genuine-failure" \
  "1" "no" "0" "blocked:no-auto-fix"

# Pre-commit passes but unstaged changes exist (e.g. hook wrote a log file)
run_precommit_retry_test "precommit-passes-with-unstaged" \
  "0" "yes" "0" "pass:clean"

# Pre-commit fails, auto-fix retry passes, but retry left unstaged changes
run_precommit_retry_test "precommit-retry-passes-but-left-unstaged" \
  "1" "yes" "0" "blocked:retry-left-unstaged" "yes"

# ---------------------------------------------------------------------------
# Test helper — reimplements the FULLSEND_VALIDATED_ITERATION_DIR selection
# logic from post-fix.sh section 5. Given an env var value and a set of files
# on disk, returns which result file would be selected.
#
# Mirrors the three-branch logic: expected filename → result.json fallback →
# fail closed with error (no silent rescan).
# ---------------------------------------------------------------------------
resolve_fix_result() {
  local validated_dir="$1"    # value of FULLSEND_VALIDATED_ITERATION_DIR ("" = unset)
  local run_dir="$2"          # directory containing iteration-*/output/

  if [ -n "${validated_dir}" ]; then
    if [ -f "${validated_dir}/agent-result.json" ]; then
      echo "${validated_dir}/agent-result.json"
    else
      echo "error:neither-filename"
    fi
  else
    local result=""
    for dir in "${run_dir}"/iteration-*/output; do
      if [ -f "${dir}/agent-result.json" ]; then
        result="${dir}/agent-result.json"
      fi
    done
    if [ -z "${result}" ]; then
      echo "error:not-found"
    else
      echo "${result}"
    fi
  fi
}

RESOLVE_TMPDIR="$(mktemp -d)"

run_resolve_test() {
  local test_name="$1"
  local setup_fn="$2"
  local expected="$3"

  local run_dir="${RESOLVE_TMPDIR}/${test_name}"
  local validated_dir="${run_dir}/validated-output"
  mkdir -p "${run_dir}"

  # Let the setup function create the directory structure.
  ${setup_fn} "${run_dir}" "${validated_dir}"

  local actual
  actual="$(resolve_fix_result "${validated_dir}" "${run_dir}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_resolve_test_unset() {
  local test_name="$1"
  local setup_fn="$2"
  local expected="$3"

  local run_dir="${RESOLVE_TMPDIR}/${test_name}"
  mkdir -p "${run_dir}"

  ${setup_fn} "${run_dir}" ""

  local actual
  actual="$(resolve_fix_result "" "${run_dir}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Setup: validated dir has agent-result.json
setup_fix_expected() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
  echo '{}' > "${validated_dir}/agent-result.json"
  # Also place a file in iteration-2 to verify it's NOT used.
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{}' > "${run_dir}/iteration-2/output/agent-result.json"
}

# Setup: validated dir has neither filename
setup_fix_neither() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
}

# Setup: env var unset, iteration dirs present (backward compat)
setup_fix_iteration_scan() {
  local run_dir="$1"
  mkdir -p "${run_dir}/iteration-1/output"
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{}' > "${run_dir}/iteration-1/output/agent-result.json"
  echo '{}' > "${run_dir}/iteration-2/output/agent-result.json"
}

# --- FULLSEND_VALIDATED_ITERATION_DIR test cases ---

run_resolve_test "fix-validated-dir-expected-filename" \
  setup_fix_expected \
  "${RESOLVE_TMPDIR}/fix-validated-dir-expected-filename/validated-output/agent-result.json"

run_resolve_test "fix-validated-dir-neither-filename" \
  setup_fix_neither \
  "error:neither-filename"

run_resolve_test_unset "fix-unset-falls-back-to-scan" \
  setup_fix_iteration_scan \
  "${RESOLVE_TMPDIR}/fix-unset-falls-back-to-scan/iteration-2/output/agent-result.json"

rm -rf "${RESOLVE_TMPDIR}"

# ---------------------------------------------------------------------------
# Integration test — run the REAL post-fix.sh to verify that it exits non-zero
# when FULLSEND_VALIDATED_ITERATION_DIR is set but does not contain
# agent-result.json. This catches the fail-open bug that the
# isolated reimplementation tests above cannot detect.
#
# Strategy: initialize a bare git repo on the main branch so NO_PUSH=true,
# which skips sections 0-4 (secret scan, pre-commit, push) and goes straight
# to the FULLSEND_VALIDATED_ITERATION_DIR check in section 5.
# ---------------------------------------------------------------------------

INTEGRATION_TMPDIR="$(mktemp -d)"
MOCK_BIN="${INTEGRATION_TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"

# Mock gh: silently accept all calls (needed for ERR trap's report_post_failure_to_pr).
cat > "${MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

run_postfix_integration_test() {
  local test_name="$1"
  local expect_failure="$2"  # "true" if we expect non-zero exit

  local run_dir="${INTEGRATION_TMPDIR}/run-${test_name}"
  local validated_dir="${run_dir}/validated-output"
  local repo_dir="${run_dir}/repo"
  mkdir -p "${validated_dir}" "${repo_dir}"

  # Initialize a minimal git repo on the main branch so the script
  # sets NO_PUSH=true and skips sections 0-4. Set a local (repo-scoped)
  # identity explicitly — CI runners often have no global git config,
  # so `git commit` fails with "Author identity unknown" otherwise.
  git init -q -b main "${repo_dir}"
  git -C "${repo_dir}" config user.email "test@example.com"
  git -C "${repo_dir}" config user.name "Test"
  git -C "${repo_dir}" commit --allow-empty -m "init" -q

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export PUSH_TOKEN="fake-token"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_NUMBER="99"
    export TRIGGER_SOURCE="test-user"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="github"
    export FULLSEND_VALIDATED_ITERATION_DIR="${validated_dir}"
    bash "${POST_SCRIPT}"
  ) > "${INTEGRATION_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected non-zero exit but got 0"
      cat "${INTEGRATION_TMPDIR}/stdout-${test_name}.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure, got exit ${exit_code})"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${INTEGRATION_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# The "neither filename" case must exit non-zero (fail closed).
run_postfix_integration_test "integration-neither-filename-fails-closed" "true"

rm -rf "${INTEGRATION_TMPDIR}"

# ---------------------------------------------------------------------------
# Thin wrapper over the shipped classify_branch_vs_pr_head (from
# branch-guard.lib.sh), so these cases exercise production logic.
# Note: post-fix.src.sh retries and fails closed before reaching the
# classifier, so "skip" is unreachable in production.
# ---------------------------------------------------------------------------
# shellcheck source=lib/branch-guard.lib.sh
source "${SCRIPT_DIR}/lib/branch-guard.lib.sh"

check_branch_mismatch() {
  local branch="$1"
  local expected_branch="$2"

  case "$(classify_branch_vs_pr_head "${branch}" "${expected_branch}")" in
    skip)     echo "skip:no-expected-branch" ;;
    match)    echo "match" ;;
    mismatch) echo "mismatch:${branch}:expected=${expected_branch}" ;;
  esac
}

run_branch_mismatch_test() {
  local test_name="$1"
  local branch="$2"
  local expected_branch="$3"
  local expected_prefix="$4"

  local actual
  actual="$(check_branch_mismatch "${branch}" "${expected_branch}")"

  if [[ "${actual}" != ${expected_prefix}* ]]; then
    echo "FAIL: ${test_name}"
    echo "  branch:          '${branch}'"
    echo "  expected_branch: '${expected_branch}'"
    echo "  expected prefix: '${expected_prefix}'"
    echo "  actual:          '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Branch mismatch test cases ---

# Branch matches PR head ref
run_branch_mismatch_test "branch-matches-pr" \
  "agent/42-fix-widget" "agent/42-fix-widget" "match"

# Branch does not match PR head ref
run_branch_mismatch_test "branch-mismatch" \
  "agent/99-other-fix" "agent/42-fix-widget" "mismatch"

# No expected branch (gh pr view failed) — skip check
run_branch_mismatch_test "no-expected-branch" \
  "agent/42-fix-widget" "" "skip:no-expected-branch"

# ---------------------------------------------------------------------------
# PR_NUMBER numeric validation
# ---------------------------------------------------------------------------

run_numeric_validation_test() {
  local test_name="$1"
  local input="$2"
  local should_pass="$3"

  if [[ "${input}" =~ ^[1-9][0-9]*$ ]]; then
    if [ "${should_pass}" = "true" ]; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name} — '${input}' should have been rejected"
      FAILURES=$((FAILURES + 1))
    fi
  else
    if [ "${should_pass}" = "false" ]; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name} — '${input}' should have been accepted"
      FAILURES=$((FAILURES + 1))
    fi
  fi
}

run_numeric_validation_test "pr-number-valid" "42" "true"
run_numeric_validation_test "pr-number-large" "12345" "true"
run_numeric_validation_test "pr-number-regex-injection" ".*" "false"
run_numeric_validation_test "pr-number-alpha" "abc" "false"
run_numeric_validation_test "pr-number-zero" "0" "false"
run_numeric_validation_test "pr-number-leading-zero" "042" "false"
run_numeric_validation_test "pr-number-empty" "" "false"
run_numeric_validation_test "pr-number-negative" "-1" "false"
run_numeric_validation_test "pr-number-decimal" "1.5" "false"
run_numeric_validation_test "pr-number-shell-injection" "1;echo pwned" "false"

# ---------------------------------------------------------------------------
# REPO_FULL_NAME format validation (matches pre-fix.src.sh regex)
# ---------------------------------------------------------------------------

run_repo_name_validation_test() {
  local test_name="$1"
  local input="$2"
  local should_pass="$3"

  local valid=true
  if [[ ! "${input}" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+$ ]]; then
    valid=false
  elif [[ "${input}" =~ (^|/)\.\.?(/|$) ]]; then
    valid=false
  fi
  if [ "${valid}" = "true" ]; then
    if [ "${should_pass}" = "true" ]; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name} — '${input}' should have been rejected"
      FAILURES=$((FAILURES + 1))
    fi
  else
    if [ "${should_pass}" = "false" ]; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name} — '${input}' should have been accepted"
      FAILURES=$((FAILURES + 1))
    fi
  fi
}

run_repo_name_validation_test "repo-name-github-style" "owner/repo" "true"
run_repo_name_validation_test "repo-name-gitlab-nested" "group/subgroup/project" "true"
run_repo_name_validation_test "repo-name-gitlab-deep-nested" "a/b/c/d" "true"
run_repo_name_validation_test "repo-name-dots-dashes" "my.org/my-repo" "true"
run_repo_name_validation_test "repo-name-no-slash" "noslash" "false"
run_repo_name_validation_test "repo-name-empty" "" "false"
run_repo_name_validation_test "repo-name-trailing-slash" "owner/" "false"
run_repo_name_validation_test "repo-name-leading-slash" "/repo" "false"
run_repo_name_validation_test "repo-name-special-chars" "owner/repo;echo" "false"
run_repo_name_validation_test "repo-name-dotdot-segment" "owner/.." "false"
run_repo_name_validation_test "repo-name-dot-segment" "owner/." "false"
run_repo_name_validation_test "repo-name-leading-dotdot" "../repo" "false"
run_repo_name_validation_test "repo-name-middle-dotdot" "group/../evil" "false"
run_repo_name_validation_test "repo-name-middle-dot" "group/./project" "false"

# ---------------------------------------------------------------------------
# Security integration tests — verify that security controls fail closed.
# These run the REAL post-fix.sh against a minimal repo with mock binaries.
# ---------------------------------------------------------------------------

SEC_TMPDIR="$(mktemp -d)"
SEC_MOCK_BIN="${SEC_TMPDIR}/bin"
mkdir -p "${SEC_MOCK_BIN}"

cat > "${SEC_MOCK_BIN}/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${SEC_MOCK_BIN}/sleep"

run_sec_postfix_test() {
  local test_name="$1"
  local expected_marker="$2"
  local pr_number="${3:-99}"

  local run_dir="${SEC_TMPDIR}/run-${test_name}"
  local repo_dir="${run_dir}/repo"
  mkdir -p "${repo_dir}"

  git init -q -b main "${repo_dir}"
  git -C "${repo_dir}" config user.email "test@example.com"
  git -C "${repo_dir}" config user.name "Test"
  git -C "${repo_dir}" commit --allow-empty -m "init" -q
  git -C "${repo_dir}" checkout -q -b agent/99-test-fix
  git -C "${repo_dir}" commit --allow-empty -m "test change" -q

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${SEC_MOCK_BIN}:${PATH}"
    export PUSH_TOKEN="fake-token"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_NUMBER="${pr_number}"
    export TRIGGER_SOURCE="test-user"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="github"
    bash "${POST_SCRIPT}"
  ) > "${SEC_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit but got 0"
    cat "${SEC_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [ -n "${expected_marker}" ] \
     && ! grep -q "${expected_marker}" "${SEC_TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — exited ${exit_code} but missing: ${expected_marker}"
    cat "${SEC_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name} (expected failure, got exit ${exit_code})"
}

# --- gh pr view API failure → fail closed (not fail open) ---
cat > "${SEC_MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") exit 1 ;;
  "pr comment"|"issue comment") printf '%s\n' "$@"; exit 0 ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "${SEC_MOCK_BIN}/gh"

run_sec_postfix_test "security-api-failure-fails-closed" "Could not resolve"

rm -rf "${SEC_TMPDIR}"

# ---------------------------------------------------------------------------
# GitLab forge tests — verify that the fix agent post-script works with
# FULLSEND_FORGE=gitlab (curl-based operations, no gh calls).
# ---------------------------------------------------------------------------

GL_TMPDIR="$(mktemp -d)"
GL_MOCK_BIN="${GL_TMPDIR}/bin"
mkdir -p "${GL_MOCK_BIN}"

cat > "${GL_MOCK_BIN}/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${GL_MOCK_BIN}/sleep"

# Mock curl — tracks calls and returns MR head ref for merge request queries
cat > "${GL_MOCK_BIN}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
MOCK_DIR="${GL_MOCK_DIR:-/tmp}"
echo "$@" >> "${MOCK_DIR}/curl-calls.log"
# Respond to merge_requests/:iid GET with source_branch
if echo "$@" | grep -q "merge_requests/"; then
  if echo "$@" | grep -q "notes"; then
    # POST note — just succeed
    exit 0
  fi
  echo '{"source_branch": "agent/99-test-fix", "iid": 99}'
  exit 0
fi
# Respond to labels POST — succeed silently
if echo "$@" | grep -q "/labels"; then
  exit 0
fi
exit 0
MOCKEOF
chmod +x "${GL_MOCK_BIN}/curl"

# Ensure gh is NOT available on PATH for GitLab tests
cat > "${GL_MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "ERROR: gh should not be called in GitLab mode" >&2
exit 1
MOCKEOF
chmod +x "${GL_MOCK_BIN}/gh"

run_gitlab_postfix_test() {
  local test_name="$1"
  local expect_failure="${2:-false}"
  local check_no_gh="${3:-false}"

  local run_dir="${GL_TMPDIR}/run-${test_name}"
  local repo_dir="${run_dir}/repo"
  local mock_dir="${run_dir}/mocks"
  mkdir -p "${repo_dir}" "${mock_dir}"

  git init -q -b main "${repo_dir}"
  git -C "${repo_dir}" config user.email "test@example.com"
  git -C "${repo_dir}" config user.name "Test"
  git -C "${repo_dir}" commit --allow-empty -m "init" -q
  git -C "${repo_dir}" checkout -q -b agent/99-test-fix
  git -C "${repo_dir}" commit --allow-empty -m "test change" -q

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${GL_MOCK_BIN}:${PATH}"
    export PUSH_TOKEN="fake-gitlab-token"
    export GITLAB_TOKEN="fake-gitlab-token"
    export REPO_FULL_NAME="test-group/test-project"
    export REPO_ENCODED="test-group%2Ftest-project"
    export GITLAB_HOST="gitlab.com"
    export CI_SERVER_HOST="gitlab.com"
    export PR_NUMBER="99"
    export PR_URL="https://gitlab.com/test-group/test-project/-/merge_requests/99"
    export TRIGGER_SOURCE="test-user"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="gitlab"
    export GL_MOCK_DIR="${mock_dir}"
    bash "${POST_SCRIPT}"
  ) > "${GL_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected non-zero exit but got 0"
      cat "${GL_TMPDIR}/stdout-${test_name}.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure, got exit ${exit_code})"
  else
    if [[ ${exit_code} -ne 0 ]]; then
      echo "FAIL: ${test_name} — exit code ${exit_code}"
      cat "${GL_TMPDIR}/stdout-${test_name}.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name}"
  fi

  # Verify no gh calls were made in GitLab mode
  if [[ "${check_no_gh}" == "true" ]]; then
    if grep -q "gh should not be called" "${GL_TMPDIR}/stdout-${test_name}.log" 2>/dev/null; then
      echo "FAIL: ${test_name} — gh was called in GitLab mode"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name}-no-gh-calls"
  fi
}

# GitLab: happy-path — successful push flow
run_gitlab_postfix_test "gitlab-happy-path" "false" "true"

# GitLab: missing PR_URL → fail closed (unbound variable)
run_gitlab_postfix_pr_url_test() {
  local test_name="$1"
  local expect_failure="${2:-true}"

  local run_dir="${GL_TMPDIR}/run-${test_name}"
  local repo_dir="${run_dir}/repo"
  local mock_dir="${run_dir}/mocks"
  mkdir -p "${repo_dir}" "${mock_dir}"

  git init -q -b main "${repo_dir}"
  git -C "${repo_dir}" config user.email "test@example.com"
  git -C "${repo_dir}" config user.name "Test"
  git -C "${repo_dir}" commit --allow-empty -m "init" -q
  git -C "${repo_dir}" checkout -q -b agent/99-test-fix
  git -C "${repo_dir}" commit --allow-empty -m "test change" -q

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${GL_MOCK_BIN}:${PATH}"
    export PUSH_TOKEN="fake-gitlab-token"
    export GITLAB_TOKEN="fake-gitlab-token"
    export REPO_FULL_NAME="test-group/test-project"
    export REPO_ENCODED="test-group%2Ftest-project"
    export GITLAB_HOST="gitlab.com"
    export CI_SERVER_HOST="gitlab.com"
    export PR_NUMBER="99"
    # PR_URL intentionally NOT set
    export TRIGGER_SOURCE="test-user"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="gitlab"
    export GL_MOCK_DIR="${mock_dir}"
    bash "${POST_SCRIPT}"
  ) > "${GL_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected non-zero exit but got 0"
      cat "${GL_TMPDIR}/stdout-${test_name}.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure, got exit ${exit_code})"
  else
    if [[ ${exit_code} -ne 0 ]]; then
      echo "FAIL: ${test_name} — exit code ${exit_code}"
      cat "${GL_TMPDIR}/stdout-${test_name}.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name}"
  fi
}

run_gitlab_postfix_pr_url_test "gitlab-missing-pr-url-fails-closed" "true"

# GitLab: GITLAB_HOST mismatch with PR_URL host → fail closed
run_gitlab_postfix_host_mismatch_test() {
  local test_name="$1"

  local run_dir="${GL_TMPDIR}/run-${test_name}"
  local repo_dir="${run_dir}/repo"
  local mock_dir="${run_dir}/mocks"
  mkdir -p "${repo_dir}" "${mock_dir}"

  git init -q -b main "${repo_dir}"
  git -C "${repo_dir}" config user.email "test@example.com"
  git -C "${repo_dir}" config user.name "Test"
  git -C "${repo_dir}" commit --allow-empty -m "init" -q
  git -C "${repo_dir}" checkout -q -b agent/99-test-fix
  git -C "${repo_dir}" commit --allow-empty -m "test change" -q

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${GL_MOCK_BIN}:${PATH}"
    export PUSH_TOKEN="fake-gitlab-token"
    export GITLAB_TOKEN="fake-gitlab-token"
    export REPO_FULL_NAME="test-group/test-project"
    export REPO_ENCODED="test-group%2Ftest-project"
    export GITLAB_HOST="evil.example.com"
    export CI_SERVER_HOST="gitlab.com"
    export PR_NUMBER="99"
    export PR_URL="https://gitlab.com/test-group/test-project/-/merge_requests/99"
    export TRIGGER_SOURCE="test-user"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="gitlab"
    export GL_MOCK_DIR="${mock_dir}"
    bash "${POST_SCRIPT}"
  ) > "${GL_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit but got 0"
    cat "${GL_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "does not match PR URL host" "${GL_TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected GITLAB_HOST mismatch error"
    cat "${GL_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name} (expected failure, got exit ${exit_code})"
}

run_gitlab_postfix_host_mismatch_test "gitlab-host-mismatch-fails-closed"

# GitLab: API failure on MR head ref → fail closed
cat > "${GL_MOCK_BIN}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
MOCK_DIR="${GL_MOCK_DIR:-/tmp}"
echo "$@" >> "${MOCK_DIR}/curl-calls.log"
# Fail on merge_requests queries (simulates API failure)
if echo "$@" | grep -q "merge_requests/" && ! echo "$@" | grep -q "notes"; then
  exit 1
fi
# POST note — succeed (for failure reporting)
if echo "$@" | grep -q "notes"; then
  exit 0
fi
exit 0
MOCKEOF
chmod +x "${GL_MOCK_BIN}/curl"

run_gitlab_postfix_test "gitlab-api-failure-fails-closed" "true" "true"

# GitLab: PR_URL with host not in dynamic trust sources → fail closed
# Validates forge_validate_pr_url rejects hosts outside the allowlist.
run_gitlab_postfix_invalid_host_test() {
  local test_name="$1"

  local run_dir="${GL_TMPDIR}/run-${test_name}"
  local repo_dir="${run_dir}/repo"
  local mock_dir="${run_dir}/mocks"
  mkdir -p "${repo_dir}" "${mock_dir}"

  git init -q -b main "${repo_dir}"
  git -C "${repo_dir}" config user.email "test@example.com"
  git -C "${repo_dir}" config user.name "Test"
  git -C "${repo_dir}" commit --allow-empty -m "init" -q
  git -C "${repo_dir}" checkout -q -b agent/99-test-fix
  git -C "${repo_dir}" commit --allow-empty -m "test change" -q

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${GL_MOCK_BIN}:${PATH}"
    export PUSH_TOKEN="fake-gitlab-token"
    export GITLAB_TOKEN="fake-gitlab-token"
    export REPO_FULL_NAME="evil-org/evil-project"
    export PR_NUMBER="1"
    export PR_URL="https://evil.com/evil-org/evil-project/-/merge_requests/1"
    export CI_SERVER_HOST="gitlab.com"
    export TRIGGER_SOURCE="test-user"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="gitlab"
    export GL_MOCK_DIR="${mock_dir}"
    bash "${POST_SCRIPT}"
  ) > "${GL_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit but got 0"
    cat "${GL_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "does not match CI_SERVER_HOST" "${GL_TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected CI_SERVER_HOST mismatch error"
    cat "${GL_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name} (expected failure, got exit ${exit_code})"
}

# Restore the working curl mock before running this test
cat > "${GL_MOCK_BIN}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
MOCK_DIR="${GL_MOCK_DIR:-/tmp}"
echo "$@" >> "${MOCK_DIR}/curl-calls.log"
if echo "$@" | grep -q "merge_requests/"; then
  if echo "$@" | grep -q "notes"; then
    exit 0
  fi
  echo '{"source_branch": "agent/99-test-fix", "iid": 99}'
  exit 0
fi
if echo "$@" | grep -q "/labels"; then
  exit 0
fi
exit 0
MOCKEOF
chmod +x "${GL_MOCK_BIN}/curl"

run_gitlab_postfix_invalid_host_test "gitlab-invalid-host-rejected"

rm -rf "${GL_TMPDIR}"

# ---------------------------------------------------------------------------
# Pre-fix validation tests — verify pre-fix.src.sh rejects mismatched
# REPO_FULL_NAME / PR_URL and PR_NUMBER / PR_URL combinations.
# ---------------------------------------------------------------------------

PRE_SCRIPT="$(resolve_agent_script pre-fix "${SCRIPT_DIR}")"
PRE_TMPDIR="$(mktemp -d)"

run_prefix_validation_test() {
  local test_name="$1"
  local expected_marker="$2"
  local repo_full_name="$3"
  local pr_number="$4"
  local pr_url="$5"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    export FULLSEND_FORGE="gitlab"
    export CI_SERVER_HOST="gitlab.com"
    export REPO_FULL_NAME="${repo_full_name}"
    export PR_NUMBER="${pr_number}"
    export PR_URL="${pr_url}"
    export TRIGGER_SOURCE="test-user"
    export FIX_ITERATION="1"
    bash "${PRE_SCRIPT}"
  ) > "${PRE_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit but got 0"
    cat "${PRE_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [[ -n "${expected_marker}" ]] \
     && ! grep -q "${expected_marker}" "${PRE_TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — exited ${exit_code} but missing: ${expected_marker}"
    cat "${PRE_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name} (expected failure, got exit ${exit_code})"
}

# REPO_FULL_NAME does not match the repo in PR_URL
run_prefix_validation_test "prefix-repo-mismatch" \
  "does not match PR URL repo" \
  "foo/bar" "99" \
  "https://gitlab.com/baz/qux/-/merge_requests/99"

# PR_NUMBER does not match the MR IID in PR_URL
run_prefix_validation_test "prefix-pr-number-mismatch" \
  "does not match PR URL number" \
  "test-group/test-project" "42" \
  "https://gitlab.com/test-group/test-project/-/merge_requests/99"

# GitHub pre-fix: nested REPO_FULL_NAME must be rejected
run_prefix_github_validation_test() {
  local test_name="$1"
  local expected_marker="$2"
  local repo_full_name="$3"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    export FULLSEND_FORGE="github"
    export REPO_FULL_NAME="${repo_full_name}"
    export PR_NUMBER="42"
    export TRIGGER_SOURCE="test-user"
    export FIX_ITERATION="1"
    bash "${PRE_SCRIPT}"
  ) > "${PRE_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit but got 0"
    cat "${PRE_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [[ -n "${expected_marker}" ]] \
     && ! grep -q "${expected_marker}" "${PRE_TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — exited ${exit_code} but missing: ${expected_marker}"
    cat "${PRE_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name} (expected failure, got exit ${exit_code})"
}

# GitHub rejects nested paths (3+ segments)
run_prefix_github_validation_test "prefix-github-nested-repo" \
  "must be owner/repo format" \
  "group/subgroup/project"

# GitHub rejects path traversal
run_prefix_github_validation_test "prefix-github-dotdot" \
  "must not contain" \
  "owner/.."

rm -rf "${PRE_TMPDIR}"

# --- Summary ---

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
