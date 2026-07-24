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
    if [ -f "${validated_dir}/fix-result.json" ]; then
      echo "${validated_dir}/fix-result.json"
    elif [ -f "${validated_dir}/result.json" ]; then
      echo "${validated_dir}/result.json"
    else
      echo "error:neither-filename"
    fi
  else
    local result=""
    for dir in "${run_dir}"/iteration-*/output; do
      if [ -f "${dir}/fix-result.json" ]; then
        result="${dir}/fix-result.json"
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

# Setup: validated dir has fix-result.json
setup_fix_expected() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
  echo '{}' > "${validated_dir}/fix-result.json"
  # Also place a file in iteration-2 to verify it's NOT used.
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{}' > "${run_dir}/iteration-2/output/fix-result.json"
}

# Setup: validated dir has only result.json
setup_fix_fallback() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
  echo '{}' > "${validated_dir}/result.json"
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
  echo '{}' > "${run_dir}/iteration-1/output/fix-result.json"
  echo '{}' > "${run_dir}/iteration-2/output/fix-result.json"
}

# --- FULLSEND_VALIDATED_ITERATION_DIR test cases ---

run_resolve_test "fix-validated-dir-expected-filename" \
  setup_fix_expected \
  "${RESOLVE_TMPDIR}/fix-validated-dir-expected-filename/validated-output/fix-result.json"

run_resolve_test "fix-validated-dir-fallback-filename" \
  setup_fix_fallback \
  "${RESOLVE_TMPDIR}/fix-validated-dir-fallback-filename/validated-output/result.json"

run_resolve_test "fix-validated-dir-neither-filename" \
  setup_fix_neither \
  "error:neither-filename"

run_resolve_test_unset "fix-unset-falls-back-to-scan" \
  setup_fix_iteration_scan \
  "${RESOLVE_TMPDIR}/fix-unset-falls-back-to-scan/iteration-2/output/fix-result.json"

rm -rf "${RESOLVE_TMPDIR}"

# ---------------------------------------------------------------------------
# Integration test — run the REAL post-fix.sh to verify that it exits non-zero
# when FULLSEND_VALIDATED_ITERATION_DIR is set but contains neither
# fix-result.json nor result.json. This catches the fail-open bug that the
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
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export PUSH_TOKEN="fake-token"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_NUMBER="99"
    export TRIGGER_SOURCE="test-user"
    export REPO_DIR="repo"
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

# --- Summary ---

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
