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

# Fetch + rebase must run after forge_set_push_remote and before the push
# so reconstructed GitLab history becomes a fast-forward (issue #1228).
if ! grep -q 'git fetch origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-fetches-remote-branch-before-push"
  echo "  ${POST_SCRIPT} missing force-update fetch of origin/\${BRANCH}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-fetches-remote-branch-before-push"
fi

if ! grep -q 'git rebase "origin/${BRANCH}"' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-rebases-onto-remote-before-push"
  echo "  ${POST_SCRIPT} missing rebase onto origin/\${BRANCH}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-rebases-onto-remote-before-push"
fi

# A conflicted rebase must fail closed, not be swallowed with || true.
if ! grep -q 'git rebase --abort' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-aborts-conflicted-rebase"
  echo "  ${POST_SCRIPT} missing git rebase --abort on conflict"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-aborts-conflicted-rebase"
fi

if grep -E 'git rebase "origin/\$\{BRANCH\}".*\|\| true' "${POST_SCRIPT}" >/dev/null; then
  echo "FAIL: bundled-script-does-not-ignore-rebase-failure"
  echo "  ${POST_SCRIPT} swallows rebase failure with || true"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-does-not-ignore-rebase-failure"
fi

# Agent rebase onto the target must not be replayed onto the stale remote PR
# tip (issue #565). The skip is what lets --force-with-lease publish it.
if ! grep -q 'skipping rebase onto origin/${BRANCH} to preserve the agent rebase onto the target' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-preserves-agent-rebase-onto-target"
  echo "  ${POST_SCRIPT} missing skip of origin/BRANCH rebase after agent rebase onto target"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-preserves-agent-rebase-onto-target"
fi

# Branch ancestry alone can't distinguish an authorized agent rebase from a
# GitLab MR reconstruction against a target that has since moved on — both
# produce the same topology (see push-rebase-reconstructed-target-advanced-no-marker
# below). The skip must additionally require agent-result.json's own record
# of having run the rebase, read via jq before the skip's if-condition.
if ! grep -q "AGENT_REBASED_ONTO_TARGET=\"\$(jq -r 'if .rebased_onto_target == true then \"true\" else \"false\" end'" "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-gates-rebase-skip-on-agent-result"
  echo "  ${POST_SCRIPT} does not read rebased_onto_target from agent-result.json"
  FAILURES=$((FAILURES + 1))
elif ! grep -q 'if \[ "${AGENT_REBASED_ONTO_TARGET}" = "true" \]' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-gates-rebase-skip-on-agent-result"
  echo "  ${POST_SCRIPT} does not gate the origin/BRANCH-rebase skip on AGENT_REBASED_ONTO_TARGET"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-gates-rebase-skip-on-agent-result"
fi

# Agent squash/redo must not be replayed onto the pre-rewrite remote PR
# tip (issue #1332). The skip is what lets --force-with-lease publish it.
if ! grep -q 'skipping rebase onto origin/${BRANCH} to preserve the agent history rewrite' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-preserves-agent-history-rewrite"
  echo "  ${POST_SCRIPT} missing skip of origin/BRANCH rebase after agent squash/reset"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-preserves-agent-history-rewrite"
fi

# history_rewritten is sandbox-written; the skip must read it via jq and
# additionally require a harness-verified human squash/redo request.
if ! grep -q "AGENT_HISTORY_REWRITTEN=\"\$(jq -r 'if .history_rewritten == true then \"true\" else \"false\" end'" "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-gates-history-rewrite-skip-on-agent-result"
  echo "  ${POST_SCRIPT} does not read history_rewritten from agent-result.json"
  FAILURES=$((FAILURES + 1))
elif ! grep -q 'HUMAN_HISTORY_REWRITE_REQUESTED' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-gates-history-rewrite-skip-on-agent-result"
  echo "  ${POST_SCRIPT} does not gate the squash/reset skip on a human rewrite request"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-gates-history-rewrite-skip-on-agent-result"
fi

if ! grep -q 'history_rewrite_preserves_remote_human_commits' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-refuses-rewrite-that-drops-human-commits"
  echo "  ${POST_SCRIPT} missing fail-closed check that remote human commits remain ancestors of HEAD"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-refuses-rewrite-that-drops-human-commits"
fi

# agent-result.json is sandbox-written and attacker-influenceable (prompt
# injection, a confused agent). rebased_onto_target alone must not be
# trusted to skip the origin/BRANCH rebase — require the harness-set
# TRIGGER_SOURCE to also indicate a human trigger, since a genuine rebase
# never happens on a bot-triggered run (see review on PR #1296).
if ! grep -q '! is_bot_user "${TRIGGER_SOURCE}"' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-requires-non-bot-trigger-for-rebase-skip"
  echo "  ${POST_SCRIPT} does not gate the origin/BRANCH-rebase skip on a non-bot TRIGGER_SOURCE"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-requires-non-bot-trigger-for-rebase-skip"
fi

# ---------------------------------------------------------------------------
# Keyword detection for human squash / redo requests (issue #1332).
# Sourced from fix-ops.lib.sh — the same functions the post-script uses.
# ---------------------------------------------------------------------------
FULLSEND_FORGE=github
# shellcheck source=lib/fix-ops.lib.sh
source "${SCRIPT_DIR}/lib/fix-ops.lib.sh"

run_history_rewrite_request_test() {
  local test_name="$1"
  local instruction="$2"
  local expect_squash="$3"
  local expect_reset="$4"
  local actual_squash=false actual_reset=false actual_rewrite=false

  if is_human_squash_request "${instruction}"; then actual_squash=true; fi
  if is_human_reset_request "${instruction}"; then actual_reset=true; fi
  if is_human_history_rewrite_request "${instruction}"; then actual_rewrite=true; fi

  local expect_rewrite=false
  if [ "${expect_squash}" = "true" ] || [ "${expect_reset}" = "true" ]; then
    expect_rewrite=true
  fi

  if [ "${actual_squash}" != "${expect_squash}" ] \
    || [ "${actual_reset}" != "${expect_reset}" ] \
    || [ "${actual_rewrite}" != "${expect_rewrite}" ]; then
    echo "FAIL: ${test_name}"
    echo "  instruction:     '${instruction}'"
    echo "  squash:          actual=${actual_squash} expected=${expect_squash}"
    echo "  reset:           actual=${actual_reset} expected=${expect_reset}"
    echo "  rewrite:         actual=${actual_rewrite} expected=${expect_rewrite}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_history_rewrite_request_test "rewrite-request-squash" \
  "squash these commits" "true" "false"
run_history_rewrite_request_test "rewrite-request-squash-bare" \
  "squash" "true" "false"
run_history_rewrite_request_test "rewrite-request-squash-case" \
  "Squash the fix commits" "true" "false"
run_history_rewrite_request_test "rewrite-request-redo-from-scratch" \
  "redo from scratch" "false" "true"
run_history_rewrite_request_test "rewrite-request-start-over" \
  "start over" "false" "true"
run_history_rewrite_request_test "rewrite-request-from-scratch" \
  "please start from scratch" "false" "true"
run_history_rewrite_request_test "rewrite-request-redo-bare" \
  "redo" "false" "true"
run_history_rewrite_request_test "rewrite-request-ordinary-fix" \
  "fix the typo in the README" "false" "false"
run_history_rewrite_request_test "rewrite-request-rebase-is-not-squash" \
  "rebase onto main" "false" "false"
run_history_rewrite_request_test "rewrite-request-empty" \
  "" "false" "false"
run_history_rewrite_request_test "rewrite-request-merge-conflict-is-not-reset" \
  "fix merge conflicts" "false" "false"

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
# DIFF_BASE ancestry check tests — verify that DIFF_BASE is recalculated
# using merge-base when PRE_AGENT_HEAD is not an ancestor of HEAD (rebase).
# This prevents false positives in the Signed-off-by and gitleaks checks
# when upstream commits contain trailers or flagged content. (Issue #318)
# ---------------------------------------------------------------------------

REBASE_TMPDIR="$(mktemp -d)"
REBASE_MOCK_BIN="${REBASE_TMPDIR}/bin"
mkdir -p "${REBASE_MOCK_BIN}"

cat > "${REBASE_MOCK_BIN}/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${REBASE_MOCK_BIN}/sleep"

# Mock gh: return the expected branch name for pr view (gh --jq outputs the
# extracted value, not JSON), accept everything else.
cat > "${REBASE_MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    # gh --jq '.headRefName' outputs just the string value
    echo 'agent/99-test-fix'
    exit 0
    ;;
  "pr comment"|"issue comment")
    # Echo --body value so test assertions can grep for failure details.
    while [ $# -gt 0 ]; do
      case "$1" in
        --body) echo "$2"; break ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  "api "*) exit 0 ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "${REBASE_MOCK_BIN}/gh"

# Mock gitleaks: always pass (the test targets DIFF_BASE logic, not gitleaks)
cat > "${REBASE_MOCK_BIN}/gitleaks" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${REBASE_MOCK_BIN}/gitleaks"

# Mock pre-commit: not installed (skip pre-commit gate)
# No mock needed — command -v will fail naturally.

# The fix agent's fresh force-fetch of origin/${TARGET_BRANCH} (PR #1335)
# calls forge_set_push_remote first, which would otherwise rewrite the
# test's local "fake origin" (set up below) to a real github.com URL. Same
# no-op-`remote set-url` wrapper as the push-rebase fixtures further down,
# so the fetch stays against the local fake origin.
REBASE_REAL_GIT="$(which git)"
cat > "${REBASE_MOCK_BIN}/git" <<MOCKEOF
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\$2" = "set-url" ]; then
  exit 0
fi
exec ${REBASE_REAL_GIT} "\$@"
MOCKEOF
chmod +x "${REBASE_MOCK_BIN}/git"

run_rebase_diffbase_test() {
  local test_name="$1"

  local run_dir="${REBASE_TMPDIR}/run-${test_name}"
  local repo_dir="${run_dir}/repo"
  mkdir -p "${repo_dir}"

  # Build a repo that simulates a rebase scenario:
  #   main:   init -- upstream (with Signed-off-by trailer)
  #   branch: init -- upstream -- agent-commit (rebased onto main)
  #
  # PRE_AGENT_HEAD is set to the pre-rebase branch tip, which is NOT
  # an ancestor of HEAD after the rebase.

  git init -q -b main "${repo_dir}"
  git -C "${repo_dir}" config user.email "test@example.com"
  git -C "${repo_dir}" config user.name "Test"
  git -C "${repo_dir}" commit --allow-empty -m "init" -q

  # Create a feature branch BEFORE the upstream commit with Signed-off-by
  git -C "${repo_dir}" checkout -q -b agent/99-test-fix
  git -C "${repo_dir}" commit --allow-empty -m "branch work" -q
  local pre_rebase_head
  pre_rebase_head="$(git -C "${repo_dir}" rev-parse HEAD)"

  # Go back to main, add a commit with Signed-off-by trailer
  git -C "${repo_dir}" checkout -q main
  git -C "${repo_dir}" commit --allow-empty \
    -m "upstream change

Signed-off-by: Human User <human@example.com>" -q

  # Simulate a rebase: recreate the branch on top of main
  git -C "${repo_dir}" checkout -q agent/99-test-fix
  git -C "${repo_dir}" rebase -q main

  # Add the "agent" commit with a real file change (no Signed-off-by).
  # The commit must touch a file so CHANGED_FILES is non-empty and NO_PUSH
  # stays false — otherwise the Signed-off-by check is skipped entirely.
  echo "agent fix" > "${repo_dir}/agent-fix.txt"
  git -C "${repo_dir}" add agent-fix.txt
  git -C "${repo_dir}" commit -m "fix: agent change" -q

  # Set up a fake origin so merge-base works
  git -C "${repo_dir}" remote add origin "${repo_dir}" 2>/dev/null || true
  git -C "${repo_dir}" fetch -q origin main 2>/dev/null || true

  local exit_code=0
  local stdout_log="${REBASE_TMPDIR}/stdout-${test_name}.log"
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${REBASE_MOCK_BIN}:${PATH}"
    export PUSH_TOKEN="fake-token"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_NUMBER="99"
    export TRIGGER_SOURCE="test-user"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="github"
    export TARGET_BRANCH="main"
    export PRE_AGENT_HEAD="${pre_rebase_head}"
    bash "${POST_SCRIPT}"
  ) > "${stdout_log}" 2>&1 || exit_code=$?

  # With the fix, the script must NOT reject with a Signed-off-by false
  # positive. The upstream commit has a legitimate Signed-off-by trailer
  # that would be in SCAN_RANGE if DIFF_BASE were not recalculated.
  # Match the specific rejection message — not progress lines like
  # "Checking for Signed-off-by trailers" or "no trailers".
  if grep -q "Agent commit contains a Signed-off-by trailer" "${stdout_log}"; then
    echo "FAIL: ${test_name} — false positive Signed-off-by rejection after rebase"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # Verify the Signed-off-by scan ran and passed (not just skipped).
  if grep -q "Signed-off-by scan passed" "${stdout_log}"; then
    echo "PASS: ${test_name}"
  else
    # The Signed-off-by check must actually execute — a pass without
    # the scan running means NO_PUSH is true (CHANGED_FILES was empty),
    # which would mask the bug this test exists to catch.
    echo "FAIL: ${test_name} — Signed-off-by check did not execute (NO_PUSH=true?)"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
}

# After rebase, PRE_AGENT_HEAD is not an ancestor — the fix should detect
# this and use merge-base, preventing a false positive on the upstream
# Signed-off-by trailer.
run_rebase_diffbase_test "rebase-diffbase-no-false-positive"

rm -rf "${REBASE_TMPDIR}"

# Signed-off-by trailer stripping is covered by scripts/signoff-strip-test.sh,
# which exercises the real rewrite (git filter-branch / git commit --amend)
# against real repositories: identity and date preservation, commit counts,
# authorship scoping, the folded-subject case, and the failure paths.

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

# ---------------------------------------------------------------------------
# Fetch + rebase before push (issue #1228).
#
# On GitLab the sandbox reconstructs the MR source branch from API content,
# so local history diverges from the remote. post-fix.sh must fetch the real
# remote tip and rebase onto it so the push is a fast-forward. A git wrapper
# no-ops `remote set-url` so origin stays the local bare remote (the real
# script rewrites origin to a forge URL after forge_set_push_remote).
# ---------------------------------------------------------------------------

PUSH_REBASE_TMPDIR="$(mktemp -d)"
PUSH_REBASE_MOCK_BIN="${PUSH_REBASE_TMPDIR}/bin"
mkdir -p "${PUSH_REBASE_MOCK_BIN}"

cat > "${PUSH_REBASE_MOCK_BIN}/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${PUSH_REBASE_MOCK_BIN}/sleep"

cat > "${PUSH_REBASE_MOCK_BIN}/gitleaks" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${PUSH_REBASE_MOCK_BIN}/gitleaks"

cat > "${PUSH_REBASE_MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    echo 'agent/99-test-fix'
    exit 0
    ;;
  "pr comment"|"issue comment")
    while [ $# -gt 0 ]; do
      case "$1" in
        --body) echo "$2"; break ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
MOCKEOF
chmod +x "${PUSH_REBASE_MOCK_BIN}/gh"

PUSH_REBASE_REAL_GIT="$(which git)"
cat > "${PUSH_REBASE_MOCK_BIN}/git" <<MOCKEOF
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\$2" = "set-url" ]; then
  exit 0
fi
exec ${PUSH_REBASE_REAL_GIT} "\$@"
MOCKEOF
chmod +x "${PUSH_REBASE_MOCK_BIN}/git"

push_rebase_ident() {
  git -C "$1" config user.email "test@example.com"
  git -C "$1" config user.name "Test"
}

run_push_rebase_postfix() {
  local run_dir="$1"
  local stdout_log="$2"
  local mock_bin="${3:-${PUSH_REBASE_MOCK_BIN}}"
  local trigger_source="${4:-test-user}"
  local human_instruction="${5:-}"
  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${mock_bin}:${PATH}"
    export PUSH_TOKEN="fake-token"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_NUMBER="99"
    export TRIGGER_SOURCE="${trigger_source}"
    export HUMAN_INSTRUCTION="${human_instruction}"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="github"
    export TARGET_BRANCH="main"
    # Needed only when a test fixture provides an iteration-N/output/agent-result.json
    # (process-fix-result.py requires it once jsonschema is importable); harmless
    # for the tests here that never populate that file.
    export FULLSEND_OUTPUT_SCHEMA="${SCRIPT_DIR}/../schemas/fix-result.schema.json"
    export GIT_BOT_EMAIL="${GIT_BOT_EMAIL:-}"
    bash "${POST_SCRIPT}"
  ) > "${stdout_log}" 2>&1 || exit_code=$?
  return "${exit_code}"
}

# Reconstructed local history (different SHAs, same tree as the real remote
# tip) plus an agent fix. Fetch+rebase must replay the fix onto the real
# remote tip so the push is a fast-forward of that tip.
run_push_rebase_reconstructed_test() {
  local test_name="push-rebase-reconstructed-history-fast-forward"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  # Reconstruct from main: same tree as A, different SHA, then the agent fix.
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "pr-a" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "Branch agent/99-test-fix pushed successfully" "${stdout_log}"; then
    echo "FAIL: ${test_name} — push did not report success"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — remote tip is not a fast-forward of real A"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_content
  remote_content="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:file.txt)"
  if [ "${remote_content}" != "fixed" ]; then
    echo "FAIL: ${test_name} — remote file.txt is '${remote_content}', want 'fixed'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Local already matches remote (GitHub-style fetch in the sandbox). Rebase
# is a no-op; the agent's commit SHA is unchanged and the push fast-forwards.
run_push_rebase_matching_history_test() {
  local test_name="push-rebase-matching-history-noop"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main
  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"
  local local_f
  local_f="$(git -C "${base}/repo" rev-parse HEAD)"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local pushed_f
  pushed_f="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${pushed_f}" != "${local_f}" ]; then
    echo "FAIL: ${test_name} — agent commit SHA changed (rebase was not a no-op)"
    echo "  before: ${local_f}"
    echo "  after:  ${pushed_f}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Remote feature branch does not exist yet. Fetch fails, rebase is skipped,
# and the push creates the branch.
run_push_rebase_fresh_branch_test() {
  local test_name="push-rebase-fresh-branch-skips-rebase"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -b agent/99-test-fix
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "skipping rebase" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected fetch miss to skip rebase"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" show-ref --verify --quiet \
       refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — remote branch was not created"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Remote has a new commit that textually conflicts with the agent's fix.
# Rebase must fail closed with an actionable message; nothing is pushed.
run_push_rebase_conflict_test() {
  local test_name="push-rebase-conflict-fails-closed"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "aaa" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  echo "bbb" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real B"
  git -C "${base}/seed" push -q origin agent/99-test-fix
  local real_b
  real_b="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" reset -q --hard "${real_a}"
  echo "fff" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit on rebase conflict"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "conflict with the agent's changes" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing actionable rebase-conflict message"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_tip
  remote_tip="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${remote_tip}" != "${real_b}" ]; then
    echo "FAIL: ${test_name} — remote branch moved on conflict (pushed anyway)"
    echo "  want ${real_b}, got ${remote_tip}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Remote feature branch exists (reconstructed/divergent history), but the
# fetch itself fails transiently (network blip, auth hiccup) rather than
# reporting a missing ref. This must fail closed — not be treated the same
# as a genuinely missing branch and fall through to a non-fast-forward push.
run_push_rebase_fetch_failure_test() {
  local test_name="push-rebase-transient-fetch-failure-fails-closed"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "pr-a" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  local fetch_fail_bin="${base}/bin"
  mkdir -p "${fetch_fail_bin}"
  cp "${PUSH_REBASE_MOCK_BIN}/sleep" "${fetch_fail_bin}/sleep"
  cp "${PUSH_REBASE_MOCK_BIN}/gitleaks" "${fetch_fail_bin}/gitleaks"
  cp "${PUSH_REBASE_MOCK_BIN}/gh" "${fetch_fail_bin}/gh"
  local fetch_fail_real_git="${PUSH_REBASE_REAL_GIT}"
  cat > "${fetch_fail_bin}/git" <<MOCKEOF
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\$2" = "set-url" ]; then
  exit 0
fi
if [ "\$1" = "fetch" ]; then
  echo "fatal: unable to access remote: Could not resolve host" >&2
  exit 128
fi
exec ${fetch_fail_real_git} "\$@"
MOCKEOF
  chmod +x "${fetch_fail_bin}/git"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" "${fetch_fail_bin}" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit on transient fetch failure"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "skipping rebase" "${stdout_log}"; then
    echo "FAIL: ${test_name} — transient fetch failure was treated as a missing branch"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "Could not fetch remote branch" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing actionable fetch-failure message"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_tip
  remote_tip="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${remote_tip}" != "${real_a}" ]; then
    echo "FAIL: ${test_name} — remote branch moved on transient fetch failure (pushed anyway)"
    echo "  want ${real_a}, got ${remote_tip}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Agent rebased the PR onto a target that has moved past the remote PR tip.
# post-fix must skip rebase onto origin/BRANCH (which would undo it) and
# force-push the rebased history (issue #565).
run_push_rebase_preserves_agent_rebase_onto_target_test() {
  local test_name="push-rebase-preserves-agent-rebase-onto-target"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "pr A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix

  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main
  local main_ahead
  main_ahead="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" rebase -q origin/main
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  # The skip is gated on the agent's own record of having run the rebase
  # (issue #565 remediation) — ancestry alone is not trusted. Without this
  # file present with rebased_onto_target:true, the skip must not fire.
  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "human",
  "actions": [
    {"type": "fix", "finding": "rebase onto main", "description": "Rebased the branch onto origin/main per the human /fs-fix rebase request."}
  ],
  "summary": "Rebased onto main.",
  "tests_passed": true,
  "files_changed": [],
  "rebased_onto_target": true
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" "test-user" "rebase onto main" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent rebase onto the target" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${main_ahead}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch is not based on the new main tip"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_content
  remote_content="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:file.txt)"
  if [ "${remote_content}" != "fixed" ]; then
    echo "FAIL: ${test_name} — remote file.txt is '${remote_content}', want 'fixed'"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local other_content
  other_content="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:other.txt)"
  if [ "${other_content}" != "ahead" ]; then
    echo "FAIL: ${test_name} — remote other.txt is '${other_content}', want 'ahead'"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# agent-result.json's rebased_onto_target is written inside the sandbox and
# is attacker-influenceable (prompt injection, a confused agent). A
# bot-triggered run never legitimately performs a human rebase (see
# agents/fix.md's "Rebase onto the target branch"), so the skip must not
# trust rebased_onto_target:true when TRIGGER_SOURCE is a bot — even though
# the ancestry conditions match (high-severity finding on PR #1296). Reuses
# the exact topology from run_push_rebase_reconstructed_target_advanced_test
# (an ordinary stale-PR reconstruction with no real rebase performed) to
# prove the marker alone — without a human trigger — cannot force the skip.
run_push_rebase_bot_trigger_ignores_marker_test() {
  local test_name="push-rebase-bot-trigger-ignores-marker"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "pr-a" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  # A bot-triggered run cannot have legitimately performed the rebase this
  # field claims — the marker must be ignored regardless of its value.
  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "bot",
  "actions": [
    {"type": "fix", "finding": "unrelated review finding", "description": "some fix"}
  ],
  "summary": "Bot-triggered fix run.",
  "tests_passed": true,
  "files_changed": [],
  "rebased_onto_target": true
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "skipping rebase onto origin/agent/99-test-fix" "${stdout_log}"; then
    echo "FAIL: ${test_name} — trusted rebased_onto_target:true from a bot-triggered run"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "Branch agent/99-test-fix pushed successfully" "${stdout_log}"; then
    echo "FAIL: ${test_name} — push did not report success"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — remote tip is not a fast-forward of real A (history was replaced instead of fast-forwarded)"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# A non-bot TRIGGER_SOURCE alone must not authorize the skip (medium-severity
# auth-bypass finding on PR #1296): any human /fs-fix run — including one
# whose instruction has nothing to do with rebasing — previously satisfied
# "! is_bot_user" and could trust rebased_onto_target:true unconditionally.
# Reuses the bot-trigger test's stale-reconstruction topology (no rebase
# ever requested) but with a genuine human TRIGGER_SOURCE and an unrelated
# HUMAN_INSTRUCTION, proving the marker plus a merely-human trigger still
# cannot force the skip — HUMAN_INSTRUCTION itself must ask for a rebase.
run_push_rebase_human_non_rebase_instruction_ignores_marker_test() {
  local test_name="push-rebase-non-rebase-instruction-ignores-marker"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "pr-a" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  # A confused/injected agent sets the marker even though the human's own
  # instruction never asked for a rebase — the marker must still be ignored.
  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "human",
  "actions": [
    {"type": "fix", "finding": "unrelated review finding", "description": "some fix"}
  ],
  "summary": "Human-triggered fix run, no rebase requested.",
  "tests_passed": true,
  "files_changed": [],
  "rebased_onto_target": true
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" "test-user" "fix the typo in the README" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "skipping rebase onto origin/agent/99-test-fix" "${stdout_log}"; then
    echo "FAIL: ${test_name} — trusted rebased_onto_target:true from a non-rebase human instruction"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "Branch agent/99-test-fix pushed successfully" "${stdout_log}"; then
    echo "FAIL: ${test_name} — push did not report success"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — remote tip is not a fast-forward of real A (history was replaced instead of fast-forwarded)"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Missing combination flagged on PR #1296's review: a GitLab-style stale
# reconstruction (target advanced past the commit the real remote PR branch
# was built from — same topology as the bot-trigger and no-marker fixtures
# above) where the marker is set AND the trigger is a genuine human
# /fs-fix rebase request. This is the legitimate case the whole gate exists
# to allow — assert the skip actually fires here, not just that it's
# refused for bot triggers and unrelated human instructions.
run_push_rebase_human_rebase_request_skips_stale_reconstruction_test() {
  local test_name="push-rebase-human-rebase-request-skips-stale-reconstruction"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix

  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "pr-a" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "human",
  "actions": [
    {"type": "fix", "finding": "rebase onto main", "description": "Rebased the branch onto origin/main per the human /fs-fix rebase request."}
  ],
  "summary": "Rebased onto main.",
  "tests_passed": true,
  "files_changed": [],
  "rebased_onto_target": true
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" "test-user" "rebase onto main" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent rebase onto the target" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH for a genuine human rebase request"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "Branch agent/99-test-fix pushed successfully" "${stdout_log}"; then
    echo "FAIL: ${test_name} — push did not report success"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_content
  remote_content="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:file.txt)"
  if [ "${remote_content}" != "fixed" ]; then
    echo "FAIL: ${test_name} — remote file.txt is '${remote_content}', want 'fixed'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Untested combination of the #1228 and #565 fixtures (per review on PR #1296):
# a GitLab-style reconstruction (branch rebuilt from API content on top of
# the *current* target tip, per run_push_rebase_reconstructed_test) where the
# target has since advanced past the commit the real remote PR branch was
# built from. No agent-result.json is present — no rebase was ever requested
# or performed — so this must NOT match the "agent rebased onto target" skip.
# Before the #565 remediation, ancestry alone made this indistinguishable
# from an authorized rebase: it would skip the origin/BRANCH rebase and
# force-push, replacing the real remote branch's history instead of
# fast-forwarding it (reintroducing the #1228 regression). The fix agent
# must fast-forward onto the real remote tip like any other stale-PR case.
run_push_rebase_reconstructed_target_advanced_test() {
  local test_name="push-rebase-reconstructed-target-advanced-no-marker"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  # Target moves on after the real remote PR branch was built — the
  # ordinary "stale PR" case that #1228's fast-forward fix exists for.
  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  # Reconstruct from the now-advanced main: same tree as A, different SHA,
  # then the agent fix. No rebase was requested or run — no agent-result.json
  # is written for this test.
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "pr-a" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "skipping rebase onto origin/agent/99-test-fix" "${stdout_log}"; then
    echo "FAIL: ${test_name} — incorrectly skipped rebase onto origin/BRANCH with no rebase marker present"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "Branch agent/99-test-fix pushed successfully" "${stdout_log}"; then
    echo "FAIL: ${test_name} — push did not report success"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — remote tip is not a fast-forward of real A (history was replaced instead of fast-forwarded)"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_content
  remote_content="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:file.txt)"
  if [ "${remote_content}" != "fixed" ]; then
    echo "FAIL: ${test_name} — remote file.txt is '${remote_content}', want 'fixed'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Validation-loop retry (per review on PR #1296): the rebase happens in an
# earlier iteration and the marker is set there, then a later iteration
# rewrites agent-result.json (e.g. to fix a schema violation) without
# redoing `git rebase` — agents/fix.md now instructs the agent to carry
# rebased_onto_target forward in that later file rather than drop it. The
# backward-compat scan in post-fix.src.sh picks the *last* iteration-N/output
# directory found, so the final agent-result.json (the retry's) is what must
# still carry the marker for the skip to fire.
run_push_rebase_preserves_agent_rebase_after_validation_retry_test() {
  local test_name="push-rebase-preserves-agent-rebase-after-validation-retry"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "pr A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix

  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main
  local main_ahead
  main_ahead="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" rebase -q origin/main
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  # iteration-1: the run that actually executed the rebase and recorded it.
  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "human",
  "actions": [
    {"type": "fix", "finding": "rebase onto main", "description": "Rebased the branch onto origin/main per the human /fs-fix rebase request."}
  ],
  "summary": "Rebased onto main.",
  "tests_passed": true,
  "files_changed": [],
  "rebased_onto_target": true
}
JSONEOF

  # iteration-2: a validation-loop retry in the same run that rewrote
  # agent-result.json (e.g. after a schema-validation failure) without
  # redoing `git rebase` — the marker must be carried forward here too.
  mkdir -p "${base}/iteration-2/output"
  cat > "${base}/iteration-2/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "human",
  "actions": [
    {"type": "fix", "finding": "rebase onto main", "description": "Rebased the branch onto origin/main per the human /fs-fix rebase request."}
  ],
  "summary": "Rebased onto main.",
  "tests_passed": true,
  "files_changed": [],
  "rebased_onto_target": true
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" "test-user" "rebase onto main" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent rebase onto the target" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH using the retry's agent-result.json"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${main_ahead}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch is not based on the new main tip"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

write_history_rewritten_result() {
  local dest_dir="$1"
  mkdir -p "${dest_dir}"
  cat > "${dest_dir}/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "human",
  "actions": [
    {"type": "fix", "finding": "squash fix-agent commits", "description": "Squashed 3 in-scope fix-agent commits onto the rewrite base."}
  ],
  "summary": "Squashed fix-agent history.",
  "tests_passed": true,
  "files_changed": ["file.txt"],
  "history_rewritten": true
}
JSONEOF
}

commit_as() {
  local repo="$1" email="$2" name="$3" msg="$4"
  GIT_AUTHOR_NAME="${name}" GIT_AUTHOR_EMAIL="${email}" \
  GIT_COMMITTER_NAME="${name}" GIT_COMMITTER_EMAIL="${email}" \
    git -C "${repo}" commit -q -m "${msg}"
}

# Agent squashed the contiguous fix-agent suffix. post-fix must skip rebase
# onto origin/BRANCH (which would restore the unsquashed commits) and
# force-push the squashed history (issue #1332).
run_push_history_rewrite_preserves_squash_test() {
  local test_name="push-history-rewrite-preserves-squash"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  echo "f2" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 2"
  echo "f3" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 3"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" reset -q --soft origin/main
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: squashed fix-agent commits"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "squash these commits" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent history rewrite" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_count
  remote_count="$(git --git-dir="${base}/remote.git" rev-list --count refs/heads/main..refs/heads/agent/99-test-fix)"
  if [ "${remote_count}" != "1" ]; then
    echo "FAIL: ${test_name} — expected 1 commit on the PR after squash, got ${remote_count}"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_content
  remote_content="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:file.txt)"
  if [ "${remote_content}" != "f3" ]; then
    echo "FAIL: ${test_name} — remote file.txt is '${remote_content}', want 'f3'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Agent reset the contiguous fix-agent suffix and re-committed. post-fix
# must skip replay onto origin/BRANCH so the discarded attempts stay gone.
run_push_history_rewrite_preserves_redo_test() {
  local test_name="push-history-rewrite-preserves-redo"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "bad1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: bad attempt 1"
  echo "bad2" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: bad attempt 2"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" reset -q --hard origin/main
  echo "redone" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: redo from scratch"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "redo from scratch" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent history rewrite" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_content
  remote_content="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:file.txt)"
  if [ "${remote_content}" != "redone" ]; then
    echo "FAIL: ${test_name} — remote file.txt is '${remote_content}', want 'redone'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix | grep -q "bad attempt"; then
    echo "FAIL: ${test_name} — discarded redo commits are still on the remote"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Ordinary append: no history_rewritten marker, no squash/redo instruction.
# New commit on top of the remote tip must fast-forward; no skip.
run_push_history_rewrite_ordinary_append_test() {
  local test_name="push-history-rewrite-ordinary-append"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "pr A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "fix the typo in the README" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "skipping rebase onto origin/agent/99-test-fix" "${stdout_log}"; then
    echo "FAIL: ${test_name} — ordinary append skipped origin/BRANCH rebase"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — remote tip is not a fast-forward of the previous PR tip"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Mixed history: a squash now targets the whole PR, so the human commit
# below the fix-agent commits is combined into the single final commit
# rather than kept separate (agents/fix.md "Rewrite fix-agent history" —
# "the end result should be a single-commit PR").
run_push_history_rewrite_preserves_human_suffix_test() {
  local test_name="push-history-rewrite-combines-human-and-fix-commits"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"
  local human_email="human@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "human" > "${base}/seed/human.txt"
  git -C "${base}/seed" add human.txt
  commit_as "${base}/seed" "${human_email}" "Alice" "feat: human work"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  echo "f2" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 2"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  # Whole-PR squash: reset to the merge base with the target, not to the
  # human commit — the human commit is part of what gets combined.
  git -C "${base}/repo" reset -q --soft origin/main
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: squashed the whole PR"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "squash these commits" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent history rewrite" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_count
  remote_count="$(git --git-dir="${base}/remote.git" rev-list --count refs/heads/main..refs/heads/agent/99-test-fix)"
  if [ "${remote_count}" != "1" ]; then
    echo "FAIL: ${test_name} — expected 1 commit on the PR after squash, got ${remote_count}"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  local human_file
  human_file="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:human.txt)"
  if [ "${human_file}" != "human" ]; then
    echo "FAIL: ${test_name} — human.txt is '${human_file}', want 'human'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Squash fail-closed: the agent recorded history_rewritten:true for a squash
# request, but the rewritten range still has more than one commit ahead of
# the target — a partial squash. Per-commit preservation no longer applies
# to squash (that check is not meaningful once commits are combined), but
# the "single-commit PR" outcome is exactly what verifies a squash actually
# did its job; a partial squash must be refused rather than force-pushed.
run_push_history_rewrite_refuses_partial_squash_test() {
  local test_name="push-history-rewrite-refuses-partial-squash"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  echo "f2" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 2"
  echo "f3" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 3"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local remote_tip
  remote_tip="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  # Partial squash: only the last two attempts are combined, leaving two
  # commits ahead of main instead of one.
  git -C "${base}/repo" reset -q --soft HEAD~2
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: squashed attempts 2 and 3"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "squash these commits" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit for a squash that left more than one commit"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "must produce exactly one commit" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing fail-closed message about the partial squash"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local after
  after="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${after}" != "${remote_tip}" ]; then
    echo "FAIL: ${test_name} — remote branch moved despite fail-closed rewrite"
    echo "  want ${remote_tip}, got ${after}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Mixed history fail-closed: agent reset past a human commit. Refuse to
# publish; leave the remote branch untouched.
run_push_history_rewrite_refuses_lost_human_commit_test() {
  local test_name="push-history-rewrite-refuses-lost-human-commit"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"
  local human_email="human@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "human" > "${base}/seed/human.txt"
  git -C "${base}/seed" add human.txt
  commit_as "${base}/seed" "${human_email}" "Alice" "feat: human work"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local remote_tip
  remote_tip="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" reset -q --hard origin/main
  echo "gone" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: redo past human"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "redo from scratch" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit when a human commit would be lost"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "human-authored commit" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing fail-closed message about the lost human commit"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local after
  after="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${after}" != "${remote_tip}" ]; then
    echo "FAIL: ${test_name} — remote branch moved despite fail-closed rewrite"
    echo "  want ${remote_tip}, got ${after}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Fail-closed: agent resets past a code-agent commit that shares the bot
# email with the fix agent — harness/fix.yaml and harness/code.yaml both set
# GIT_AUTHOR_EMAIL/GIT_COMMITTER_EMAIL to the same GIT_BOT_EMAIL, differing
# only by GIT_AUTHOR_NAME (fullsend-fix vs fullsend-code). An email-only
# droppable classification would treat this code-agent commit as the fix
# agent's own no-op work and let the redo silently discard the code agent's
# original PR contribution (fail-open finding on PR #1335).
run_push_history_rewrite_refuses_lost_code_agent_commit_test() {
  local test_name="push-history-rewrite-refuses-lost-code-agent-commit"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "code" > "${base}/seed/code.txt"
  git -C "${base}/seed" add code.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "feat: code agent work"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local remote_tip
  remote_tip="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" reset -q --hard origin/main
  echo "gone" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: redo past code agent"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "redo from scratch" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit when a code-agent commit would be lost"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "fullsend-code" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing fail-closed message naming the lost code-agent commit"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local after
  after="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${after}" != "${remote_tip}" ]; then
    echo "FAIL: ${test_name} — remote branch moved despite fail-closed rewrite"
    echo "  want ${remote_tip}, got ${after}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Target branch advances after the PR was opened, and the agent squashes
# only the fix-agent suffix in place (not rebased onto the new target). The
# fork point (merge-base of the two remote refs) still identifies the PR's
# original base even though origin/main is no longer an ancestor of the
# squashed HEAD — see the logic-error finding on PR #1335 at
# post-fix.src.sh:494.
run_push_history_rewrite_preserves_squash_target_advanced_test() {
  local test_name="push-history-rewrite-preserves-squash-target-advanced"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  echo "f2" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 2"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix

  # Target moves on after the PR branch was built.
  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "main ahead"
  git -C "${base}/seed" push -q origin main

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  # Squash the fix-agent suffix in place — NOT rebased onto the advanced main.
  local fork_point
  fork_point="$(git -C "${base}/repo" merge-base origin/main HEAD)"
  git -C "${base}/repo" reset -q --soft "${fork_point}"
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: squashed fix-agent commits"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "squash these commits" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent history rewrite" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH even though the target advanced"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_count
  remote_count="$(git --git-dir="${base}/remote.git" rev-list --count refs/heads/main..refs/heads/agent/99-test-fix)"
  if [ "${remote_count}" != "1" ]; then
    echo "FAIL: ${test_name} — expected 1 commit on the PR after squash, got ${remote_count}"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_content
  remote_content="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:file.txt)"
  if [ "${remote_content}" != "f2" ]; then
    echo "FAIL: ${test_name} — remote file.txt is '${remote_content}', want 'f2'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Combined "rebase and squash" (agents/fix.md: "If the instruction asks for
# a rebase and a squash, rebase first, then squash the authorized range on
# the rebased history"). The rebase-skip block's ancestry requirement
# (target has advanced past the remote PR tip) is satisfied first and sets
# SKIP_REMOTE_REBASE=true before the squash/redo block is ever reached —
# that is the ordinary reason a human asks for a rebase in the first place.
# That must not bypass history_rewrite_preserves_remote_human_commits: a
# redo that discards a human-authored commit on this combined path must
# still be refused, with the remote left untouched — see the high-severity
# logic-error finding on PR #1335 at post-fix.src.sh:505.
run_push_history_rewrite_refuses_lost_human_commit_after_rebase_test() {
  local test_name="push-history-rewrite-refuses-lost-human-commit-after-rebase"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"
  local human_email="human@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "human" > "${base}/seed/human.txt"
  git -C "${base}/seed" add human.txt
  commit_as "${base}/seed" "${human_email}" "Alice" "feat: human work"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local remote_tip
  remote_tip="$(git -C "${base}/seed" rev-parse HEAD)"

  # Target moves on after the PR branch was built — the ordinary reason a
  # human asks for a rebase.
  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "main ahead"
  git -C "${base}/seed" push -q origin main

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" rebase -q origin/main
  # Redo past the (just-rebased) human commit: reset to the rebased-onto
  # target and recommit without it — discards the human's work.
  git -C "${base}/repo" reset -q --hard origin/main
  echo "gone" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: redo past human after rebase"

  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "human",
  "actions": [
    {"type": "fix", "finding": "rebase and redo", "description": "Rebased onto main, then redid the fix-agent work from scratch."}
  ],
  "summary": "Rebased and redid fix-agent history.",
  "tests_passed": true,
  "files_changed": ["file.txt"],
  "rebased_onto_target": true,
  "history_rewritten": true
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "rebase onto main and redo from scratch" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit when a human commit would be lost on the combined rebase+redo path"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "human-authored commit" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing fail-closed message about the lost human commit"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local after
  after="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${after}" != "${remote_tip}" ]; then
    echo "FAIL: ${test_name} — remote branch moved despite fail-closed rewrite"
    echo "  want ${remote_tip}, got ${after}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# The ordinary success path agents/fix.md documents for a combined "rebase
# and squash" instruction: the target has genuinely advanced with an
# unrelated file change, the PR branch carries a human commit alongside the
# fix-agent commits, and the agent rebases onto the new target and then
# squashes the whole (rebased) PR range — human commit included — into one
# commit. The resulting commit's tree contains the target's unrelated
# change too (a real rebase reapplies every commit onto the new base), so
# the human's own contribution survives only as content within the single
# squashed commit, not as a separate commit — that is the point of a
# whole-PR squash.
run_push_history_rewrite_preserves_rebased_human_commit_test() {
  local test_name="push-history-rewrite-squashes-whole-pr-after-rebase"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"
  local human_email="human@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "human" > "${base}/seed/human.txt"
  git -C "${base}/seed" add human.txt
  commit_as "${base}/seed" "${human_email}" "Alice" "feat: human work"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  echo "f2" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 2"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local pre_rewrite_tip
  pre_rewrite_tip="$(git -C "${base}/seed" rev-parse HEAD)"

  # Target moves on after the PR branch was built — the ordinary reason a
  # human asks for a rebase.
  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "main ahead"
  git -C "${base}/seed" push -q origin main

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  # Genuine rebase: the human commit is replayed intact, but its resulting
  # tree now also contains other.txt from the advanced target.
  git -C "${base}/repo" rebase -q origin/main
  # Squash the whole rebased PR range (human commit included) into one commit.
  git -C "${base}/repo" reset -q --soft origin/main
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: squashed the whole PR"

  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "human",
  "actions": [
    {"type": "fix", "finding": "rebase and squash", "description": "Rebased onto main, then squashed the fix-agent suffix."}
  ],
  "summary": "Rebased and squashed fix-agent history.",
  "tests_passed": true,
  "files_changed": ["file.txt"],
  "rebased_onto_target": true,
  "history_rewritten": true
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "rebase onto main and squash" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local human_file
  human_file="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:human.txt)"
  if [ "${human_file}" != "human" ]; then
    echo "FAIL: ${test_name} — human.txt is '${human_file}', want 'human'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_count
  remote_count="$(git --git-dir="${base}/remote.git" rev-list --count refs/heads/main..refs/heads/agent/99-test-fix)"
  if [ "${remote_count}" != "1" ]; then
    echo "FAIL: ${test_name} — expected 1 commit on the PR after squash, got ${remote_count}"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  if git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       refs/heads/agent/99-test-fix "${pre_rewrite_tip}" 2>/dev/null; then
    echo "FAIL: ${test_name} — remote tip did not advance past the pre-rewrite state"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# The patch-id fallback's candidate search must be scoped to the range
# being published (origin/TARGET_BRANCH..HEAD), not all of HEAD's
# ancestry — HEAD also contains target-branch history up to the fork
# point, and a same-author, same-patch-id commit inherited from the
# target branch proves nothing about whether the PR's own commit
# survived the rewrite. Target history already has an older commit
# (by the same human author) that adds foo.txt with content identical
# to the PR's own later restore of that file; the agent then redoes
# past its own restore. The unscoped candidate search would find the
# older target-branch commit as a false "equivalent" and wrongly treat
# the dropped PR commit as preserved — see the medium-severity
# logic-error finding on PR #1335 at post-fix.src.sh:459.
run_push_history_rewrite_refuses_target_history_patch_id_collision_test() {
  local test_name="push-history-rewrite-refuses-target-history-patch-id-collision"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"
  local human_email="human@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "init"
  # Older same-author commit already in target history, with the exact
  # patch the PR's own restore will later reintroduce. file.txt also
  # changes here so this commit's full tree will differ from the PR's
  # later restore commit below — the collision under test must be caught
  # (or missed) by the patch-id fallback specifically, not the tree
  # fallback, which already has its own coverage.
  echo "restore-me" > "${base}/seed/foo.txt"
  git -C "${base}/seed" add foo.txt
  commit_as "${base}/seed" "${human_email}" "Alice" "feat: add foo"
  git -C "${base}/seed" rm -q foo.txt
  echo "removed-marker" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "remove foo, bump marker"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  # The PR's own restore — identical patch-id to the older target-branch
  # commit above (same file added with the same content), but a different
  # full tree (file.txt is "removed-marker" here, not "base"). This is the
  # commit that must actually be preserved.
  echo "restore-me" > "${base}/seed/foo.txt"
  git -C "${base}/seed" add foo.txt
  commit_as "${base}/seed" "${human_email}" "Alice" "feat: restore foo"
  echo "f1" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local remote_tip
  remote_tip="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  # Redo from scratch past the human's restore commit: reset to the fork
  # point (main was never advanced) and recommit without restoring foo.txt.
  git -C "${base}/repo" reset -q --hard origin/main
  echo "f2" > "${base}/repo/other.txt"
  git -C "${base}/repo" add other.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: redo from scratch"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "redo from scratch" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit; the dropped human restore commit shares a patch-id with an unrelated older target-branch commit, which must not count as preserving it"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "human-authored commit" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing fail-closed message about the lost human commit"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local after
  after="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${after}" != "${remote_tip}" ]; then
    echo "FAIL: ${test_name} — remote branch moved despite fail-closed rewrite"
    echo "  want ${remote_tip}, got ${after}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# The tree+author fallback's candidate search must be scoped to the range
# being published (origin/TARGET_BRANCH..HEAD), not all of HEAD's
# ancestry, and must match tree/author with exact field equality rather
# than `grep -qF` against a bare "tree name email" string (an unanchored
# substring match). Target history already has an older commit (by the
# same human author) whose full tree is byte-identical to the PR's own
# later restore of that content; the agent then redoes past its own
# restore. The unscoped, substring-matching candidate search would find
# the older target-branch commit as a false "equivalent" and wrongly
# treat the dropped PR commit as preserved — see the medium-severity
# fail-open finding on PR #1335 at post-fix.src.sh:451.
run_push_history_rewrite_refuses_target_history_tree_author_collision_test() {
  local test_name="push-history-rewrite-refuses-target-history-tree-author-collision"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"
  local human_email="human@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "init"
  # Older same-author commit already in target history, with the exact
  # full tree the PR's own restore will later reintroduce.
  echo "hello" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${human_email}" "Alice" "feat: set hello"
  echo "advanced" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "advance marker"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  # The PR's own restore — identical full tree to the older target-branch
  # commit above (same file content), but reached via a different parent.
  # This is the commit that must actually be preserved.
  echo "hello" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${human_email}" "Alice" "feat: restore hello"
  echo "f1" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local remote_tip
  remote_tip="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  # Redo from scratch past the human's restore commit: reset to the fork
  # point (main was never advanced) and recommit without restoring
  # file.txt to "hello".
  git -C "${base}/repo" reset -q --hard origin/main
  echo "f2" > "${base}/repo/other.txt"
  git -C "${base}/repo" add other.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: redo from scratch"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "redo from scratch" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit; the dropped human restore commit shares a full tree with an unrelated older target-branch commit, which must not count as preserving it"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "human-authored commit" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing fail-closed message about the lost human commit"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local after
  after="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${after}" != "${remote_tip}" ]; then
    echo "FAIL: ${test_name} — remote branch moved despite fail-closed rewrite"
    echo "  want ${remote_tip}, got ${after}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# A GitLab MR reconstruction can produce the exact same topology the
# squash/redo skip checks for (diverged from origin/BRANCH, still contains
# the fork point) even when no rewrite happened at all — reconstructed
# commits get new SHAs from API content even when nothing changed. The skip
# must require a rewrite-specific structural signal (fewer commits, or a
# different final tree), not topology alone — see the logic-error finding
# on PR #1335 at post-fix.src.sh:495.
run_push_history_rewrite_indistinguishable_from_reconstruction_test() {
  local test_name="push-history-rewrite-indistinguishable-from-reconstruction"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  echo "f2" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 2"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_tip
  real_tip="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  # Reconstruct the SAME two commits from API content: identical trees and
  # commit count, but different SHAs — no rewrite actually happened.
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "f1" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  echo "f2" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: attempt 2"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "squash these commits" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent history rewrite" "${stdout_log}"; then
    echo "FAIL: ${test_name} — skipped replay even though local HEAD is structurally indistinguishable from a reconstruction (same commit count and tree)"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_tip}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — remote tip is not a fast-forward of the real remote tip"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# GitLab-reconstruction-style: the sandbox never fetches the real remote
# branch, so it reconstructs the PR's content from API data under different
# commit SHAs than the real remote (different messages/dates). A squash now
# targets the whole PR as a single commit, so the reconstruction combines
# every original change — including the human's — directly into that one
# commit. Since squash verification no longer walks individual remote
# commits looking for a preserved equivalent (that check does not apply to
# a real squash at all, per PR #1335), this only needs the structural
# "genuine rewrite" signal (fewer commits than the remote range) and the
# "exactly one commit" outcome check to both hold.
run_push_history_rewrite_preserves_reconstructed_human_commit_test() {
  local test_name="push-history-rewrite-squashes-reconstructed-human-commit"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"
  local human_email="human@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "human" > "${base}/seed/human.txt"
  git -C "${base}/seed" add human.txt
  commit_as "${base}/seed" "${human_email}" "Alice" "feat: human work"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  echo "f2" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 2"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  # Reconstruct the PR's net content from API data as a single commit —
  # different SHA/message than anything on the real remote, and the human
  # commit's content is folded in rather than kept as its own commit. The
  # rewritten range (1 commit) is shorter than the remote range (3 commits)
  # — a genuine rewrite, not just a reconstruction of the same history.
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "human" > "${base}/repo/human.txt"
  git -C "${base}/repo" add human.txt
  echo "f2" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: squashed the whole PR (reconstructed)"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "squash these commits" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent history rewrite" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_count
  remote_count="$(git --git-dir="${base}/remote.git" rev-list --count refs/heads/main..refs/heads/agent/99-test-fix)"
  if [ "${remote_count}" != "1" ]; then
    echo "FAIL: ${test_name} — expected 1 commit on the PR after squash, got ${remote_count}"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  local human_file
  human_file="$(git --git-dir="${base}/remote.git" show refs/heads/agent/99-test-fix:human.txt)"
  if [ "${human_file}" != "human" ]; then
    echo "FAIL: ${test_name} — human.txt is '${human_file}', want 'human'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# history_rewritten:true from a bot-triggered run must not skip replay.
run_push_history_rewrite_bot_trigger_ignores_marker_test() {
  local test_name="push-history-rewrite-bot-trigger-ignores-marker"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  # Reconstruct A (same tree, different SHA) plus an extra agent commit so
  # replay onto origin/BRANCH is a clean fast-forward. A true squash skip
  # would replace real A; ignoring the marker must keep real A as ancestor.
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "pr-a" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent history rewrite" "${stdout_log}"; then
    echo "FAIL: ${test_name} — trusted history_rewritten:true from a bot-triggered run"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — remote tip is not a fast-forward of real A (history was replaced)"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# history_rewritten:true from an unrelated human instruction must not skip.
run_push_history_rewrite_non_rewrite_instruction_ignores_marker_test() {
  local test_name="push-history-rewrite-non-rewrite-instruction-ignores-marker"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "pr-a" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  write_history_rewritten_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "fix the typo in the README" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "skipping rebase onto origin/agent/99-test-fix to preserve the agent history rewrite" "${stdout_log}"; then
    echo "FAIL: ${test_name} — trusted history_rewritten:true from a non-rewrite human instruction"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — remote tip is not a fast-forward of real A (history was replaced)"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_push_rebase_reconstructed_test
run_push_rebase_matching_history_test
run_push_rebase_fresh_branch_test
run_push_rebase_conflict_test
run_push_rebase_fetch_failure_test
run_push_rebase_preserves_agent_rebase_onto_target_test
run_push_rebase_reconstructed_target_advanced_test
run_push_rebase_bot_trigger_ignores_marker_test
run_push_rebase_human_non_rebase_instruction_ignores_marker_test
run_push_rebase_human_rebase_request_skips_stale_reconstruction_test
run_push_rebase_preserves_agent_rebase_after_validation_retry_test
run_push_history_rewrite_preserves_squash_test
run_push_history_rewrite_refuses_partial_squash_test
run_push_history_rewrite_preserves_redo_test
run_push_history_rewrite_ordinary_append_test
run_push_history_rewrite_preserves_human_suffix_test
run_push_history_rewrite_refuses_lost_human_commit_test
run_push_history_rewrite_refuses_lost_code_agent_commit_test
run_push_history_rewrite_preserves_squash_target_advanced_test
run_push_history_rewrite_refuses_lost_human_commit_after_rebase_test
run_push_history_rewrite_preserves_rebased_human_commit_test
run_push_history_rewrite_refuses_target_history_patch_id_collision_test
run_push_history_rewrite_refuses_target_history_tree_author_collision_test
run_push_history_rewrite_indistinguishable_from_reconstruction_test
run_push_history_rewrite_preserves_reconstructed_human_commit_test
run_push_history_rewrite_bot_trigger_ignores_marker_test
run_push_history_rewrite_non_rewrite_instruction_ignores_marker_test

rm -rf "${PUSH_REBASE_TMPDIR}"

# --- Summary ---

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
