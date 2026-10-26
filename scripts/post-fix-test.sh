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

# Git Data API calls from forge_push_branch are served from the bare remote
# by the mock gh scripts below.
export FAKE_GH_GIT_API="${SCRIPT_DIR}/test-fixtures/fake-gh-git-api.sh"

POST_SCRIPT="$(resolve_agent_script post-fix "${SCRIPT_DIR}")"
if ! grep -q 'gha_echo' "${POST_SCRIPT}" || ! grep -q 'post_fail_to_pr' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-failure-reporting"
  echo "  ${POST_SCRIPT} missing gha_echo or post_fail_to_pr"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-failure-reporting"
fi

if ! grep -q 'forge_push_branch' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-signed-push"
  echo "  ${POST_SCRIPT} missing forge_push_branch"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-signed-push"
fi

# The switch that keeps the publish on git push unless enabled.
if ! grep -q 'GITHUB_SIGNED_COMMITS' "${SCRIPT_DIR}/post-fix.sh"; then
  echo "FAIL: bundled-script-has-signed-commits-switch"
  echo "  scripts/post-fix.sh does not carry the GITHUB_SIGNED_COMMITS switch"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-signed-commits-switch"
fi

if ! grep -q 'install_gitleaks' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-gitleaks-install"
  echo "  ${POST_SCRIPT} missing install_gitleaks"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-gitleaks-install"
fi

# Lib-defined code is only inlined into the bundle: in bundled mode check the
# bundle (so a stale bundle is caught), in source mode check the lib itself.
if [[ "${SCRIPT_TEST_TARGET:-source}" == "bundled" ]]; then
  FAILURE_LIB_TARGET="${POST_SCRIPT}"
else
  FAILURE_LIB_TARGET="${SCRIPT_DIR}/lib/post-failure-report.lib.sh"
fi

if ! grep -q 'forge_retry_transient' "${FAILURE_LIB_TARGET}"; then
  echo "FAIL: post-failure-has-transient-retry"
  echo "  ${FAILURE_LIB_TARGET} missing forge_retry_transient"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: post-failure-has-transient-retry"
fi

if ! grep -q 'fix-agent-failed' "${FAILURE_LIB_TARGET}"; then
  echo "FAIL: post-failure-has-last-resort-label"
  echo "  ${FAILURE_LIB_TARGET} missing fix-agent-failed last-resort label"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: post-failure-has-last-resort-label"
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

# Forge-reported conflict (issue #1518): skip replay of a merge commit so
# a default git rebase cannot drop it, and skip replay of a conflict rebase
# so the post-script does not re-hit the same conflict. Authorization is
# the runner-side forge query, not TRIGGER_SOURCE.
if ! grep -q 'via a forge-conflict merge' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-preserves-forge-conflict-merge"
  echo "  ${POST_SCRIPT} missing skip of origin/BRANCH rebase after a forge-conflict merge"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-preserves-forge-conflict-merge"
fi

if ! grep -q 'after a forge-conflict rebase' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-preserves-forge-conflict-rebase"
  echo "  ${POST_SCRIPT} missing skip of origin/BRANCH rebase after a forge-conflict rebase"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-preserves-forge-conflict-rebase"
fi

if ! grep -q 'forge_pr_has_merge_conflict' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-queries-forge-conflict"
  echo "  ${POST_SCRIPT} does not query forge mergeability before the replay skip"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-queries-forge-conflict"
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
# FIX_CONFLICT_UPDATE_STRATEGY defaulting (issue #1518)
# ---------------------------------------------------------------------------
run_conflict_strategy_test() {
  local test_name="$1"
  local raw="$2"
  local expect="$3"
  local actual
  actual="$(FIX_CONFLICT_UPDATE_STRATEGY="${raw}" fix_conflict_update_strategy)"
  if [ "${actual}" != "${expect}" ]; then
    echo "FAIL: ${test_name} — actual='${actual}' expected='${expect}' (raw='${raw}')"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}
run_conflict_strategy_test "conflict-strategy-default-empty" "" "merge"
run_conflict_strategy_test "conflict-strategy-merge" "merge" "merge"
run_conflict_strategy_test "conflict-strategy-rebase" "rebase" "rebase"
run_conflict_strategy_test "conflict-strategy-rebase-case" "Rebase" "rebase"
run_conflict_strategy_test "conflict-strategy-unknown-defaults-merge" "squash" "merge"

# Fix harness: FIX_CONFLICT_UPDATE_STRATEGY default (issue #1518). Lives here
# (rather than harness-jira-test.sh) alongside the rest of the fix-agent
# harness/fix-ops coverage.
FIX_HARNESS="${SCRIPT_DIR}/../harness/fix.yaml"
if yq -e '.env.runner.FIX_CONFLICT_UPDATE_STRATEGY == "merge"' "${FIX_HARNESS}" >/dev/null \
   && yq -e '.env.sandbox.FIX_CONFLICT_UPDATE_STRATEGY == "merge"' "${FIX_HARNESS}" >/dev/null; then
  echo "PASS: fix-conflict-strategy-default-merge"
else
  echo "FAIL: fix-conflict-strategy-default-merge — FIX_CONFLICT_UPDATE_STRATEGY must default to merge in harness/fix.yaml runner and sandbox"
  FAILURES=$((FAILURES + 1))
fi

# harness/fix.yaml ships GITHUB_SIGNED_COMMITS off, in its GitHub block
# only; the eval overlay the root config.yaml registers turns it on so the
# functional evals keep exercising the API path.
FIX_EVAL_HARNESS="${SCRIPT_DIR}/../eval/harness/fix.yaml"
ROOT_CONFIG="${SCRIPT_DIR}/../config.yaml"
if yq -e '.forge.github.env.runner.GITHUB_SIGNED_COMMITS == "false"' "${FIX_HARNESS}" >/dev/null \
   && yq -e '[.env.runner.GITHUB_SIGNED_COMMITS, .env.sandbox.GITHUB_SIGNED_COMMITS, .forge.github.env.sandbox.GITHUB_SIGNED_COMMITS, .forge.gitlab.env.runner.GITHUB_SIGNED_COMMITS, .forge.gitlab.env.sandbox.GITHUB_SIGNED_COMMITS] | map(select(. != null)) | length == 0' "${FIX_HARNESS}" >/dev/null; then
  echo "PASS: fix-harness-signed-commits-default-off"
else
  echo "FAIL: fix-harness-signed-commits-default-off — GITHUB_SIGNED_COMMITS must be \"false\" in forge.github.env.runner of harness/fix.yaml and set nowhere else"
  FAILURES=$((FAILURES + 1))
fi
if yq -e '.base == "../../harness/fix.yaml" and .env.runner.GITHUB_SIGNED_COMMITS == "true"' "${FIX_EVAL_HARNESS}" >/dev/null \
   && yq -e '.agents[] | select(.source == "eval/harness/fix.yaml")' "${ROOT_CONFIG}" >/dev/null; then
  echo "PASS: eval-fix-harness-signed-commits-on"
else
  echo "FAIL: eval-fix-harness-signed-commits-on — eval/harness/fix.yaml must extend harness/fix.yaml with GITHUB_SIGNED_COMMITS \"true\" and be registered in config.yaml"
  FAILURES=$((FAILURES + 1))
fi

# GitHub mergeable classification. Anything other than CONFLICTING is not a
# conflict — including UNKNOWN, MERGEABLE, and mergeStateStatus-like values.
run_github_conflict_class_test() {
  local test_name="$1"
  local mergeable="$2"
  local expect="$3"
  local mock_bin actual=false saved_path
  mock_bin="$(mktemp -d)"
  cat > "${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
if printf '%s' "$*" | grep -q 'mergeable'; then
  printf '%s\n' "${GH_MOCK_MERGEABLE:-}"
  exit 0
fi
echo 'main'
exit 0
MOCK
  chmod +x "${mock_bin}/gh"
  saved_path="${PATH}"
  PATH="${mock_bin}:${saved_path}"
  export REPO_FULL_NAME="o/r"
  export GH_MOCK_MERGEABLE="${mergeable}"
  if forge_pr_has_merge_conflict 99; then
    actual=true
  fi
  PATH="${saved_path}"
  unset GH_MOCK_MERGEABLE
  rm -rf "${mock_bin}"
  if [ "${actual}" != "${expect}" ]; then
    echo "FAIL: ${test_name} — actual=${actual} expected=${expect} (mergeable=${mergeable})"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}
run_github_conflict_class_test "github-conflict-conflicting" "CONFLICTING" "true"
run_github_conflict_class_test "github-conflict-mergeable" "MERGEABLE" "false"
run_github_conflict_class_test "github-conflict-unknown" "UNKNOWN" "false"
run_github_conflict_class_test "github-conflict-empty" "" "false"
run_github_conflict_class_test "github-conflict-blocked-is-not-conflict" "BLOCKED" "false"

# GitLab detailed_merge_status classification. Only "conflict" is a conflict.
# Isolated from the GitHub-sourced helpers by re-sourcing under gitlab.
run_gitlab_conflict_class_test() {
  local test_name="$1"
  local json="$2"
  local expect="$3"
  local mock_bin actual=false saved_path saved_forge
  mock_bin="$(mktemp -d)"
  printf '%s\n' "${json}" > "${mock_bin}/mr.json"
  cat > "${mock_bin}/curl" <<'MOCK'
#!/usr/bin/env bash
cat "${GL_MOCK_MR_JSON}"
exit 0
MOCK
  chmod +x "${mock_bin}/curl"
  saved_path="${PATH}"
  saved_forge="${FULLSEND_FORGE}"
  FULLSEND_FORGE=gitlab
  # Reset include guards so sourcing reloads gitlab ops after github ops.
  # shellcheck disable=SC1091
  unset FIX_OPS_SH_LOADED GITHUB_FIX_OPS_SH_LOADED GITLAB_FIX_OPS_SH_LOADED GITLAB_HOST_VALIDATION_SH_LOADED
  source "${SCRIPT_DIR}/lib/fix-ops.lib.sh"
  PATH="${mock_bin}:${saved_path}"
  export CI_SERVER_HOST="gitlab.com"
  export GITLAB_HOST="gitlab.com"
  export GITLAB_TOKEN="fake"
  export REPO_ENCODED="g%2Fp"
  export GL_MOCK_MR_JSON="${mock_bin}/mr.json"
  if forge_pr_has_merge_conflict 99; then
    actual=true
  fi
  PATH="${saved_path}"
  FULLSEND_FORGE="${saved_forge}"
  unset FIX_OPS_SH_LOADED GITHUB_FIX_OPS_SH_LOADED GITLAB_FIX_OPS_SH_LOADED GITLAB_HOST_VALIDATION_SH_LOADED
  source "${SCRIPT_DIR}/lib/fix-ops.lib.sh"
  rm -rf "${mock_bin}"
  if [ "${actual}" != "${expect}" ]; then
    echo "FAIL: ${test_name} — actual=${actual} expected=${expect}"
    echo "  json: ${json}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}
run_gitlab_conflict_class_test "gitlab-conflict-detailed-status" \
  '{"detailed_merge_status":"conflict","has_conflicts":true}' "true"
run_gitlab_conflict_class_test "gitlab-not-approved-is-not-conflict" \
  '{"detailed_merge_status":"not_approved","has_conflicts":false}' "false"
run_gitlab_conflict_class_test "gitlab-ci-must-pass-is-not-conflict" \
  '{"detailed_merge_status":"ci_must_pass"}' "false"
run_gitlab_conflict_class_test "gitlab-need-rebase-is-not-conflict" \
  '{"detailed_merge_status":"need_rebase"}' "false"
run_gitlab_conflict_class_test "gitlab-checking-is-not-conflict" \
  '{"detailed_merge_status":"checking"}' "false"
run_gitlab_conflict_class_test "gitlab-unknown-is-not-conflict" \
  '{}' "false"
run_gitlab_conflict_class_test "gitlab-legacy-cannot-be-merged-with-conflicts" \
  '{"has_conflicts":true,"merge_status":"cannot_be_merged"}' "true"
run_gitlab_conflict_class_test "gitlab-legacy-checking-with-conflicts-is-not-conflict" \
  '{"has_conflicts":true,"merge_status":"checking"}' "false"

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

  if echo "${push_output}" | grep -qi "non-fast-forward\|rejected\|fetch first\|not a fast forward"; then
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

# GitHub's wording when the API ref update loses a race → retry with --force-with-lease
run_push_retry_test "push-api-not-a-fast-forward" \
  "1" "gh: Update is not a fast forward (HTTP 422)" "retry:force-with-lease"

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
    export GITHUB_SIGNED_COMMITS="true"
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
  "api -X") exec bash "${FAKE_GH_GIT_API}" "$@" ;;
  "pr view")
    # Distinct --json fields are requested by different forge helpers.
    # Default mergeable=MERGEABLE so these DIFF_BASE tests never look like
    # a forge-reported conflict (issue #1518).
    if printf '%s' "$*" | grep -q 'headRefName'; then
      echo 'agent/99-test-fix'
    elif printf '%s' "$*" | grep -q 'baseRefName'; then
      echo 'main'
    elif printf '%s' "$*" | grep -q 'mergeable'; then
      echo 'MERGEABLE'
    else
      echo 'agent/99-test-fix'
    fi
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
if [ "${1:-}" = version ]; then echo 8.30.1; exit 0; fi
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
    export GITHUB_SIGNED_COMMITS="true"
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
    export GITHUB_SIGNED_COMMITS="true"
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
  echo '{"source_branch": "agent/99-test-fix", "iid": 99, "target_branch": "main"}'
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
  echo '{"source_branch": "agent/99-test-fix", "iid": 99, "target_branch": "main"}'
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
    export GITHUB_SIGNED_COMMITS="true"
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
# Pre-fix fetches the latest target branch when the forge reports a real
# merge conflict (issue #1518). BLOCKED / UNKNOWN / MERGEABLE must not fetch.
# ---------------------------------------------------------------------------
PREFIX_CONFLICT_TMPDIR="$(mktemp -d)"
PREFIX_CONFLICT_MOCK_BIN="${PREFIX_CONFLICT_TMPDIR}/bin"
mkdir -p "${PREFIX_CONFLICT_MOCK_BIN}"

run_prefix_conflict_fetch_test() {
  local test_name="$1"
  local mergeable="$2"
  local expect_fetch="$3"
  local base="${PREFIX_CONFLICT_TMPDIR}/${test_name}"
  mkdir -p "${base}/bin" "${base}/workspace"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  git -C "${base}/seed" config user.email "test@example.com"
  git -C "${base}/seed" config user.name "Test"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main
  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "pr"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  git clone -q "${base}/remote.git" "${base}/workspace/target-repo"
  git -C "${base}/workspace/target-repo" checkout -q agent/99-test-fix
  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main
  local main_ahead
  main_ahead="$(git -C "${base}/seed" rev-parse HEAD)"

  cat > "${base}/bin/gh" <<'MOCK'
#!/usr/bin/env bash
if printf '%s' "$*" | grep -q 'headRefName'; then
  echo 'agent/99-test-fix'
elif printf '%s' "$*" | grep -q 'baseRefName'; then
  echo 'main'
elif printf '%s' "$*" | grep -q 'mergeable'; then
  printf '%s\n' "${GH_MOCK_MERGEABLE}"
else
  echo 'agent/99-test-fix'
fi
exit 0
MOCK
  chmod +x "${base}/bin/gh"

  local stdout_log="${PREFIX_CONFLICT_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    export PATH="${base}/bin:${PATH}"
    export FULLSEND_FORGE="github"
    export GITHUB_SIGNED_COMMITS="true"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_NUMBER="99"
    export TRIGGER_SOURCE="fullsend-ai-review[bot]"
    export FIX_ITERATION="1"
    export GITHUB_WORKSPACE="${base}/workspace"
    export REPO_DIR="${base}/workspace/target-repo"
    export TARGET_BRANCH="main"
    export GH_MOCK_MERGEABLE="${mergeable}"
    bash "${PRE_SCRIPT}"
  ) > "${stdout_log}" 2>&1 || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — pre-fix exited ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local fetched="false"
  if git -C "${base}/workspace/target-repo" merge-base --is-ancestor \
       "${main_ahead}" "refs/remotes/origin/main" 2>/dev/null; then
    fetched="true"
  fi
  if [ "${expect_fetch}" = "true" ]; then
    if [ "${fetched}" != "true" ]; then
      echo "FAIL: ${test_name} — expected origin/main to be fetched to ${main_ahead}"
      cat "${stdout_log}"
      FAILURES=$((FAILURES + 1))
      return
    fi
    if ! grep -q "Fetched origin/main" "${stdout_log}"; then
      echo "FAIL: ${test_name} — missing fetch log line"
      cat "${stdout_log}"
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if [ "${fetched}" = "true" ]; then
      echo "FAIL: ${test_name} — fetched origin/main without a forge conflict"
      cat "${stdout_log}"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi
  echo "PASS: ${test_name}"
}

run_prefix_conflict_fetch_test "prefix-fetches-target-on-github-conflict" "CONFLICTING" "true"
run_prefix_conflict_fetch_test "prefix-skips-fetch-on-mergeable" "MERGEABLE" "false"
run_prefix_conflict_fetch_test "prefix-skips-fetch-on-unknown" "UNKNOWN" "false"
run_prefix_conflict_fetch_test "prefix-skips-fetch-on-blocked" "BLOCKED" "false"

# ---------------------------------------------------------------------------
# Scope-creep regression: TARGET_BRANCH must only be reassigned from
# FORGE_PR_BASE_BRANCH inside the FORGE_PR_HAS_CONFLICT branch (matching
# post-fix.src.sh's own fix for the same issue), not unconditionally on
# every pre-fix run.
# ---------------------------------------------------------------------------
conflict_if_line="$(grep -n 'if \[ "\${FORGE_PR_HAS_CONFLICT}" = "true" \]' "${PRE_SCRIPT}" | head -1 | cut -d: -f1)"
target_branch_assign_line="$(grep -n 'TARGET_BRANCH="\${FORGE_PR_BASE_BRANCH}"' "${PRE_SCRIPT}" | head -1 | cut -d: -f1)"
if [ -z "${conflict_if_line}" ] || [ -z "${target_branch_assign_line}" ]; then
  echo "FAIL: prefix-target-branch-scoped-to-conflict — could not locate the conflict guard or the TARGET_BRANCH reassignment in ${PRE_SCRIPT}"
  FAILURES=$((FAILURES + 1))
elif [ "${target_branch_assign_line}" -le "${conflict_if_line}" ]; then
  echo "FAIL: prefix-target-branch-scoped-to-conflict — TARGET_BRANCH is reassigned at line ${target_branch_assign_line}, before (or at) the FORGE_PR_HAS_CONFLICT guard at line ${conflict_if_line}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: prefix-target-branch-scoped-to-conflict"
fi

# ---------------------------------------------------------------------------
# Secret-exposure regression: forge_mask_token must run before the PUSH_TOKEN
# fetch (matching post-fix.src.sh, which masks before its own credentialed
# fetch), so a git error that echoes the remote URL can't leak the token.
# ---------------------------------------------------------------------------
mask_token_line="$(grep -n 'forge_mask_token "\${PUSH_TOKEN}"' "${PRE_SCRIPT}" | head -1 | cut -d: -f1)"
set_push_remote_line="$(grep -n 'forge_set_push_remote "\${PUSH_TOKEN}"' "${PRE_SCRIPT}" | head -1 | cut -d: -f1)"
if [ -z "${mask_token_line}" ] || [ -z "${set_push_remote_line}" ]; then
  echo "FAIL: prefix-masks-token-before-credentialed-fetch — could not locate forge_mask_token or forge_set_push_remote in ${PRE_SCRIPT}"
  FAILURES=$((FAILURES + 1))
elif [ "${mask_token_line}" -ge "${set_push_remote_line}" ]; then
  echo "FAIL: prefix-masks-token-before-credentialed-fetch — forge_mask_token (line ${mask_token_line}) does not precede forge_set_push_remote (line ${set_push_remote_line})"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: prefix-masks-token-before-credentialed-fetch"
fi

# ---------------------------------------------------------------------------
# Secret-exposure regression: a failed restore of the pre-existing origin URL
# after the conflict fetch must be fatal, not warn-and-continue — TARGET_REPO
# is mounted into the sandbox, so a credentialed URL left behind there would
# violate the "PUSH_TOKEN never enters the sandbox" contract.
# ---------------------------------------------------------------------------
run_prefix_restore_failure_fatal_test() {
  local test_name="prefix-restore-failure-is-fatal"
  local base="${PREFIX_CONFLICT_TMPDIR2}/${test_name}"
  mkdir -p "${base}/bin" "${base}/workspace"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  git -C "${base}/seed" config user.email "test@example.com"
  git -C "${base}/seed" config user.name "Test"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main
  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "pr"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  git clone -q "${base}/remote.git" "${base}/workspace/target-repo"
  git -C "${base}/workspace/target-repo" checkout -q agent/99-test-fix

  cat > "${base}/bin/gh" <<'MOCK'
#!/usr/bin/env bash
if printf '%s' "$*" | grep -q 'headRefName'; then
  echo 'agent/99-test-fix'
elif printf '%s' "$*" | grep -q 'baseRefName'; then
  echo 'main'
elif printf '%s' "$*" | grep -q 'mergeable'; then
  echo 'CONFLICTING'
else
  echo 'agent/99-test-fix'
fi
exit 0
MOCK
  chmod +x "${base}/bin/gh"

  # Allow the credentialed set-url (forge_set_push_remote, called as a plain
  # `git remote set-url origin <url>` after cd'ing into TARGET_REPO) through
  # to real git, but fail the restore — invoked as
  # `git -C TARGET_REPO remote set-url origin <url>`, so "remote"/"set-url"
  # aren't fixed at $1/$2 — to simulate a failure right after the fetch.
  cat > "${base}/bin/git" <<EOF
#!/usr/bin/env bash
args=("\$@")
last_index=\$(( \${#args[@]} - 1 ))
last_arg=""
if [ "\${last_index}" -ge 0 ]; then
  last_arg="\${args[\${last_index}]}"
fi
if printf '%s\n' "\$*" | grep -q 'remote set-url origin'; then
  case "\${last_arg}" in
    *x-access-token*) exec ${PREFIX_REAL_GIT} "\$@" ;;
    *)
      echo "simulated restore failure" >&2
      exit 1
      ;;
  esac
fi
# The credentialed origin URL (set above) points at a real github.com URL —
# redirect the fetch to the local bare remote instead of making a real
# network call; only the URL needs to look real for this test.
if printf '%s\n' "\$*" | grep -q ' fetch origin '; then
  new_args=()
  for a in "\${args[@]}"; do
    if [ "\${a}" = "origin" ]; then
      new_args+=("${base}/remote.git")
    else
      new_args+=("\${a}")
    fi
  done
  exec ${PREFIX_REAL_GIT} "\${new_args[@]}"
fi
exec ${PREFIX_REAL_GIT} "\$@"
EOF
  chmod +x "${base}/bin/git"

  local stdout_log="${PREFIX_CONFLICT_TMPDIR2}/stdout-${test_name}.log"
  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    export PATH="${base}/bin:${PATH}"
    export FULLSEND_FORGE="github"
    export GITHUB_SIGNED_COMMITS="true"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_NUMBER="99"
    export TRIGGER_SOURCE="fullsend-ai-review[bot]"
    export FIX_ITERATION="1"
    export GITHUB_WORKSPACE="${base}/workspace"
    export REPO_DIR="${base}/workspace/target-repo"
    export TARGET_BRANCH="main"
    export PUSH_TOKEN="fake-push-token"
    bash "${PRE_SCRIPT}"
  ) > "${stdout_log}" 2>&1 || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected a non-zero exit when the origin URL restore fails"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "Could not restore original origin URL" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing the restore-failure diagnostic"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

PREFIX_CONFLICT_TMPDIR2="$(mktemp -d)"
PREFIX_REAL_GIT="$(command -v git)"
run_prefix_restore_failure_fatal_test
rm -rf "${PREFIX_CONFLICT_TMPDIR2}"

rm -rf "${PREFIX_CONFLICT_TMPDIR}"

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
if [ "${1:-}" = version ]; then echo 8.30.1; exit 0; fi
exit 0
MOCKEOF
chmod +x "${PUSH_REBASE_MOCK_BIN}/gitleaks"

cat > "${PUSH_REBASE_MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api -X") exec bash "${FAKE_GH_GIT_API}" "$@" ;;
  "pr view")
    # Distinct --json fields are requested by different forge helpers.
    # Default mergeable=MERGEABLE so existing tests never look like a
    # forge-reported conflict (issue #1518).
    if printf '%s' "$*" | grep -q 'headRefName'; then
      echo 'agent/99-test-fix'
    elif printf '%s' "$*" | grep -q 'baseRefName'; then
      echo 'main'
    elif printf '%s' "$*" | grep -q 'mergeable'; then
      echo 'MERGEABLE'
    else
      echo 'agent/99-test-fix'
    fi
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

# With GITHUB_SIGNED_COMMITS off, run_push_rebase_postfix puts this gh in
# front of the mock: a Git Data API call fails the run, everything else is
# served by the mock the scenario chose (PUSH_REBASE_DELEGATE_GH).
PUSH_REBASE_OFF_BIN="${PUSH_REBASE_TMPDIR}/offbin"
mkdir -p "${PUSH_REBASE_OFF_BIN}"
cat > "${PUSH_REBASE_OFF_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [ "$1 $2" = "api -X" ]; then
  echo "unexpected Git Data API call on the plain-push path: $*" >&2
  exit 99
fi
exec "${PUSH_REBASE_DELEGATE_GH}" "$@"
MOCKEOF
chmod +x "${PUSH_REBASE_OFF_BIN}/gh"

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
  local conflict_strategy="${6:-}"
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
    export FIX_CONFLICT_UPDATE_STRATEGY="${conflict_strategy}"
    export REPO_DIR="repo"
    # Defaults to github but honors a caller-exported override (e.g.
    # FULLSEND_FORGE=gitlab run_push_rebase_postfix_with_mergeable ...) the
    # same way GIT_BOT_EMAIL below does, so GitLab-specific gating can be
    # exercised without a second copy of this harness.
    export FULLSEND_FORGE="${FULLSEND_FORGE:-github}"
    # The publish path under test: the API unless a caller exports
    # GITHUB_SIGNED_COMMITS=false, the fleet default in harness/fix.yaml.
    export GITHUB_SIGNED_COMMITS="${GITHUB_SIGNED_COMMITS:-true}"
    if [ "${GITHUB_SIGNED_COMMITS}" != "true" ]; then
      export PUSH_REBASE_DELEGATE_GH="${mock_bin}/gh"
      export PATH="${PUSH_REBASE_OFF_BIN}:${PATH}"
    fi
    if [ "${FULLSEND_FORGE}" = "gitlab" ]; then
      # Only needed on the gitlab path (setup() validates PR_URL against
      # REPO_FULL_NAME/PR_NUMBER and derives GITLAB_HOST from it); harmless
      # defaults so callers only have to override FULLSEND_FORGE itself.
      export CI_SERVER_HOST="${CI_SERVER_HOST:-gitlab.com}"
      export PR_URL="${PR_URL:-https://${CI_SERVER_HOST}/${REPO_FULL_NAME}/-/merge_requests/${PR_NUMBER}}"
      export GITLAB_TOKEN="${GITLAB_TOKEN:-fake-gitlab-token}"
      export GITLAB_HOST="${GITLAB_HOST:-${CI_SERVER_HOST}}"
      export REPO_ENCODED="${REPO_ENCODED:-$(printf '%s' "${REPO_FULL_NAME}" | tr '/' '%2F')}"
    fi
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
  # The signed push recreates the commit on GitHub, so the remote SHA differs;
  # the push log names the local commit each remote commit was built from.
  local pushed_f
  pushed_f="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if ! grep -q "Created signed commit ${pushed_f} for ${local_f}" "${stdout_log}"; then
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
  local test_name="push-rebase-preserves-agent-rebase-onto-target${1:+-$1}"
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

# commit_as_published REPO EMAIL NAME MSG [TRAILER_EMAIL] — a commit as the
# GitHub API publishes it: App bot author with EMAIL (GIT_BOT_EMAIL), GitHub
# committer, NAME <TRAILER_EMAIL> (default EMAIL) in the Authored-by trailer.
commit_as_published() {
  local repo="$1" email="$2" name="$3" msg="$4" trailer_email="${5:-$2}"
  GIT_AUTHOR_NAME='fullsend-ai-coder[bot]' GIT_AUTHOR_EMAIL="${email}" \
  GIT_COMMITTER_NAME='GitHub' GIT_COMMITTER_EMAIL='noreply@github.com' \
    git -C "${repo}" commit -q -m "${msg}" -m "Authored-by: ${name} <${trailer_email}>"
}

# run_redo_refused_test NAME SEED_FN MESSAGE_GREP — seeds a PR branch with
# SEED_FN (called with the base dir and the bot email), then a redo that
# resets to origin/main must be refused, the remote branch unchanged, and
# the fail-closed message must match MESSAGE_GREP.
run_redo_refused_test() {
  local test_name="$1" seed_fn="$2" expect_grep="$3"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"
  seed_pr_branch "${base}"
  "${seed_fn}" "${base}" "${bot_email}"
  local remote_tip
  remote_tip="$(git -C "${base}/seed" rev-parse HEAD)"
  publish_pr_branch "${base}"
  git -C "${base}/repo" reset -q --hard origin/main
  echo "gone" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  commit_as "${base}/repo" "${bot_email}" "fullsend-fix" "fix: redo past a protected commit"
  write_history_rewritten_result "${base}/iteration-1/output"
  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "redo from scratch" || exit_code=$?
  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected non-zero exit when a protected commit would be lost"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "${expect_grep}" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing fail-closed message matching '${expect_grep}'"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local after
  after="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  if [ "${after}" != "${remote_tip}" ]; then
    echo "FAIL: ${test_name} — remote branch moved despite fail-closed rewrite"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Another bot's commit (name ends in [bot], but not the App's noreply email)
# carrying a fix-agent trailer stays that bot's commit.
seed_other_bot_with_trailer() {
  local base="$1" bot_email="$2"
  echo "auto" > "${base}/seed/auto.txt"
  git -C "${base}/seed" add auto.txt
  GIT_AUTHOR_NAME='github-actions[bot]' GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
  GIT_COMMITTER_NAME='GitHub' GIT_COMMITTER_EMAIL='noreply@github.com' \
    git -C "${base}/seed" commit -q -m "chore: auto-format" -m "Authored-by: fullsend-fix <${bot_email}>"
}

# A published commit with two Authored-by trailers is ambiguous and is
# read from its git author, the bot, which is not the fix agent.
seed_published_with_two_trailers() {
  local base="$1" bot_email="$2"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  GIT_AUTHOR_NAME='fullsend-ai-coder[bot]' GIT_AUTHOR_EMAIL="${bot_email}" \
  GIT_COMMITTER_NAME='GitHub' GIT_COMMITTER_EMAIL='noreply@github.com' \
    git -C "${base}/seed" commit -q -m "fix: attempt 1" -m "Authored-by: fullsend-fix <${bot_email}>
Authored-by: fullsend-fix <${bot_email}>"
}

# A code-agent commit published through the API, then a fix attempt: the
# bot author is shared, only the Authored-by trailer tells them apart.
seed_published_code_agent_commit() {
  local base="$1" bot_email="$2"
  echo "code" > "${base}/seed/code.txt"
  git -C "${base}/seed" add code.txt
  commit_as_published "${base}/seed" "${bot_email}" "fullsend-code" "feat: code agent work"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as_published "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
}

# A human commit carrying a fix-agent Authored-by trailer: the trailer only
# counts on bot-authored commits, so the human stays the author.
seed_human_with_spoofed_trailer() {
  local base="$1" bot_email="$2"
  echo "human" > "${base}/seed/human.txt"
  git -C "${base}/seed" add human.txt
  GIT_AUTHOR_NAME="Human" GIT_AUTHOR_EMAIL="human@example.com" \
  GIT_COMMITTER_NAME="Human" GIT_COMMITTER_EMAIL="human@example.com" \
    git -C "${base}/seed" commit -q -m "feat: human work" -m "Authored-by: fullsend-fix <${bot_email}>"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as_published "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
}

# seed_pr_branch BASE — bare remote at BASE/remote.git with main at "init",
# and a clone at BASE/seed checked out on agent/99-test-fix.
seed_pr_branch() {
  local base="$1"
  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main
  git -C "${base}/seed" checkout -q -b agent/99-test-fix
}

# publish_pr_branch BASE — pushes the seed's branch and clones the remote to
# BASE/repo on that branch, as the sandbox checkout.
publish_pr_branch() {
  local base="$1"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
}

# Redo over commits published through the API: all share the bot author, so
# only the Authored-by trailer separates the fix agent's attempts
# (droppable) from the code agent's commit (preserved).
run_push_history_rewrite_preserves_redo_after_signed_push_test() {
  local test_name="push-history-rewrite-preserves-redo-after-signed-push"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"

  seed_pr_branch "${base}"
  echo "code" > "${base}/seed/code.txt"
  git -C "${base}/seed" add code.txt
  commit_as_published "${base}/seed" "${bot_email}" "fullsend-code" "feat: code agent work"
  local code_sha
  code_sha="$(git -C "${base}/seed" rev-parse HEAD)"
  echo "bad1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as_published "${base}/seed" "${bot_email}" "fullsend-fix" "fix: bad attempt 1"
  echo "bad2" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as_published "${base}/seed" "${bot_email}" "fullsend-fix" "fix: bad attempt 2"
  publish_pr_branch "${base}"
  git -C "${base}/repo" reset -q --hard "${code_sha}"
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
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor "${code_sha}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — the code agent's commit is no longer on the remote"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# A human commit already published through the API (bot author, Authored-by
# trailer) is rebased onto an advanced target. Its SHA and tree change, so
# the preservation check must find it by patch-id and the trailer author,
# and the republished commit must keep the trailer.
run_push_history_rewrite_preserves_rebased_published_human_commit_test() {
  local test_name="push-history-rewrite-preserves-rebased-published-human-commit"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"
  local bot_email="bot@example.com"
  local human_email="human@example.com"

  seed_pr_branch "${base}"
  echo "human" > "${base}/seed/human.txt"
  git -C "${base}/seed" add human.txt
  commit_as_published "${base}/seed" "${bot_email}" "Alice" "feat: human work" "${human_email}"
  echo "f1" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  commit_as_published "${base}/seed" "${bot_email}" "fullsend-fix" "fix: attempt 1"
  # Target moves on after the PR branch was built — the ordinary reason a
  # human asks for a rebase.
  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  commit_as "${base}/seed" "${bot_email}" "fullsend-code" "main ahead"
  git -C "${base}/seed" push -q origin main
  local main_ahead
  main_ahead="$(git -C "${base}/seed" rev-parse HEAD)"
  publish_pr_branch "${base}"
  git -C "${base}/repo" rebase -q origin/main

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
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${PUSH_REBASE_MOCK_BIN}" \
    "test-user" "rebase onto main" || exit_code=$?

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
  local remote="${base}/remote.git" branch="refs/heads/agent/99-test-fix"
  if ! git --git-dir="${remote}" merge-base --is-ancestor "${main_ahead}" "${branch}"; then
    echo "FAIL: ${test_name} — pushed branch is not based on the new main tip"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local remote_count
  remote_count="$(git --git-dir="${remote}" rev-list --count "refs/heads/main..${branch}")"
  if [ "${remote_count}" != "2" ]; then
    echo "FAIL: ${test_name} — expected 2 commits on the PR after the rebase, got ${remote_count}"
    git --git-dir="${remote}" log --oneline "${branch}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local human_file
  human_file="$(git --git-dir="${remote}" show "${branch}:human.txt")"
  if [ "${human_file}" != "human" ]; then
    echo "FAIL: ${test_name} — human.txt is '${human_file}', want 'human'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local human_trailer fix_trailer
  human_trailer="$(git --git-dir="${remote}" log -1 --format='%(trailers:key=Authored-by,valueonly)' "${branch}~1" | sed '/^$/d')"
  fix_trailer="$(git --git-dir="${remote}" log -1 --format='%(trailers:key=Authored-by,valueonly)' "${branch}" | sed '/^$/d')"
  if [ "${human_trailer}" != "Alice <${human_email}>" ] || [ "${fix_trailer}" != "fullsend-fix <${bot_email}>" ]; then
    echo "FAIL: ${test_name} — Authored-by trailers not kept through the rebase and republish"
    echo "  human: '${human_trailer}'  fix: '${fix_trailer}'"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Agent reset the contiguous fix-agent suffix and re-committed. post-fix
# must skip replay onto origin/BRANCH so the discarded attempts stay gone.
run_push_history_rewrite_preserves_redo_test() {
  local test_name="push-history-rewrite-preserves-redo${1:+-$1}"
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
  local test_name="push-history-rewrite-ordinary-append${1:+-$1}"
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
run_push_history_rewrite_preserves_redo_after_signed_push_test
run_redo_refused_test "push-history-rewrite-refuses-lost-published-code-agent-commit" seed_published_code_agent_commit "fullsend-code"
run_redo_refused_test "push-history-rewrite-refuses-lost-human-commit-with-spoofed-trailer" seed_human_with_spoofed_trailer "author Human <human@example.com>"
run_push_history_rewrite_preserves_rebased_published_human_commit_test
run_redo_refused_test "push-history-rewrite-refuses-lost-other-bot-commit-with-trailer" seed_other_bot_with_trailer "github-actions\[bot\]"
run_redo_refused_test "push-history-rewrite-refuses-ambiguous-double-trailer-commit" seed_published_with_two_trailers "fullsend-ai-coder\[bot\]"
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

# The fleet default (GITHUB_SIGNED_COMMITS "false" in harness/fix.yaml): the
# same publishes go through a plain git push, with any Git Data API call
# failing the run. Covers the fast-forward, lease (redo) and rebase pushes.
GITHUB_SIGNED_COMMITS=false run_push_history_rewrite_ordinary_append_test signed-commits-off
GITHUB_SIGNED_COMMITS=false run_push_history_rewrite_preserves_redo_test signed-commits-off
GITHUB_SIGNED_COMMITS=false run_push_rebase_preserves_agent_rebase_onto_target_test signed-commits-off

# ---------------------------------------------------------------------------
# Forge-reported conflict: post-fix skip of origin/BRANCH replay (issue #1518).
# ---------------------------------------------------------------------------
run_push_rebase_postfix_with_mergeable() {
  local mergeable="$1"
  shift
  local run_dir="$1"
  local stdout_log="$2"
  local mock_bin="${3:-${PUSH_REBASE_MOCK_BIN}}"
  local trigger_source="${4:-fullsend-ai-review[bot]}"
  local human_instruction="${5:-}"
  local conflict_strategy="${6:-}"
  local conflict_mock="${PUSH_REBASE_TMPDIR}/bin-conflict-${mergeable}"
  mkdir -p "${conflict_mock}"
  cp "${mock_bin}/sleep" "${conflict_mock}/sleep"
  cp "${mock_bin}/gitleaks" "${conflict_mock}/gitleaks"
  cp "${mock_bin}/git" "${conflict_mock}/git"
  cat > "${conflict_mock}/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "api -X") exec bash "\${FAKE_GH_GIT_API}" "\$@" ;;
  "pr view")
    if printf '%s' "\$*" | grep -q 'headRefName'; then
      echo 'agent/99-test-fix'
    elif printf '%s' "\$*" | grep -q 'baseRefName'; then
      echo 'main'
    elif printf '%s' "\$*" | grep -q 'mergeable'; then
      echo '${mergeable}'
    else
      echo 'agent/99-test-fix'
    fi
    exit 0
    ;;
  "pr comment"|"issue comment")
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --body) echo "\$2"; break ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${conflict_mock}/gh"
  run_push_rebase_postfix "${run_dir}" "${stdout_log}" "${conflict_mock}" \
    "${trigger_source}" "${human_instruction}" "${conflict_strategy}"
}

# GitLab counterpart of run_push_rebase_postfix_with_mergeable: mergeability
# comes from curl-based MR queries (detailed_merge_status), not `gh pr view`.
# Used for FULLSEND_FORGE=gitlab-only gating (e.g. the merged_target
# GitLab-reconstruction fallback), where flipping FULLSEND_FORGE alone is not
# enough — the gitlab code path also validates PR_URL and queries the MR via
# curl instead of gh.
run_push_rebase_postfix_gitlab_with_mergeable() {
  local merge_status="$1"
  shift
  local run_dir="$1"
  local stdout_log="$2"
  local mock_bin="${3:-${PUSH_REBASE_MOCK_BIN}}"
  # Bot suffix convention differs by forge (is_bot_user in fix-ops.lib.sh):
  # gitlab checks a trailing "_bot", not "[bot]".
  local trigger_source="${4:-fullsend-ai-review_bot}"
  local human_instruction="${5:-}"
  local conflict_strategy="${6:-}"
  local conflict_mock="${PUSH_REBASE_TMPDIR}/bin-gitlab-conflict-${merge_status}"
  mkdir -p "${conflict_mock}"
  cp "${mock_bin}/sleep" "${conflict_mock}/sleep"
  cp "${mock_bin}/gitleaks" "${conflict_mock}/gitleaks"
  cp "${mock_bin}/git" "${conflict_mock}/git"
  cat > "${conflict_mock}/curl" <<EOF
#!/usr/bin/env bash
if printf '%s' "\$*" | grep -q "merge_requests/"; then
  if printf '%s' "\$*" | grep -q "notes"; then
    exit 0
  fi
  echo '{"source_branch": "agent/99-test-fix", "iid": 99, "target_branch": "main", "detailed_merge_status": "${merge_status}"}'
  exit 0
fi
if printf '%s' "\$*" | grep -q "/labels"; then
  exit 0
fi
exit 0
EOF
  chmod +x "${conflict_mock}/curl"
  # gh must never be called on the gitlab path.
  cat > "${conflict_mock}/gh" <<'EOF'
#!/usr/bin/env bash
echo "ERROR: gh should not be called in GitLab mode" >&2
exit 1
EOF
  chmod +x "${conflict_mock}/gh"
  FULLSEND_FORGE="gitlab" \
    run_push_rebase_postfix "${run_dir}" "${stdout_log}" "${conflict_mock}" \
    "${trigger_source}" "${human_instruction}" "${conflict_strategy}"
}

write_merged_target_result() {
  local dir="$1"
  mkdir -p "${dir}"
  cat > "${dir}/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "bot",
  "actions": [
    {"type": "fix", "finding": "forge merge conflict", "description": "Merged origin/main into the PR branch."}
  ],
  "summary": "Merged target to resolve forge-reported conflict.",
  "tests_passed": true,
  "files_changed": ["file.txt"],
  "merged_target": true,
  "conflict_update": {
    "forge_state": "CONFLICTING",
    "target_branch": "main",
    "strategy": "merge",
    "outcome": "merged"
  }
}
JSONEOF
}

run_push_preserves_forge_conflict_merge_test() {
  local test_name="push-preserves-forge-conflict-merge"
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
  git -C "${base}/repo" merge -q --no-edit origin/main
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  write_merged_target_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix_with_mergeable "CONFLICTING" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "via a forge-conflict merge" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${main_ahead}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch does not contain the new main tip"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local parents
  parents="$(git --git-dir="${base}/remote.git" rev-list --max-count=20 --merges refs/heads/agent/99-test-fix)"
  if [ -z "${parents}" ]; then
    echo "FAIL: ${test_name} — merge commit was dropped by replay"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Medium-severity logic-error finding: for a merge commit, PRE_AGENT_HEAD
# stays an ancestor of HEAD, so DIFF_BASE is unchanged and the two-dot
# `git diff DIFF_BASE..HEAD` compares final trees directly (not scoped to
# first-parent). An "ours"-resolved forge conflict — a valid resolution that
# keeps the PR's own content over every incoming target change — produces a
# merge tree identical to the first parent, so this diff is empty even
# though the merge commit itself is a real, publishable resolution. Without
# accounting for a merge commit being present, NO_PUSH is forced true and
# the resolution is never pushed, leaving the PR/MR CONFLICTING on the
# remote despite the agent having resolved it. This fixture has no
# follow-up commit after the merge (unlike the other forge-conflict-merge
# tests here), which is exactly what exercises the bug.
run_push_forge_conflict_merge_ours_resolution_no_diff_test() {
  local test_name="push-forge-conflict-merge-ours-resolution-no-diff"
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
  local pr_a_sha
  pr_a_sha="$(git -C "${base}/seed" rev-parse HEAD)"

  git -C "${base}/seed" checkout -q main
  echo "main-ahead" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "main ahead (conflicting)"
  git -C "${base}/seed" push -q origin main

  # The agent resolves the forge-reported conflict by keeping its own
  # content over every incoming target change ("ours"), producing a merge
  # commit whose tree is identical to its first parent — and adds no
  # follow-up commit at all.
  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" merge -q --no-edit -s ours origin/main

  write_merged_target_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  PRE_AGENT_HEAD="${pr_a_sha}" \
    run_push_rebase_postfix_with_mergeable "CONFLICTING" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "No changed files in agent's commit(s)" "${stdout_log}"; then
    echo "FAIL: ${test_name} — an ours-resolved merge with no follow-up commit was incorrectly treated as nothing to push"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local merges
  merges="$(git --git-dir="${base}/remote.git" rev-list --max-count=20 --merges refs/heads/agent/99-test-fix 2>/dev/null)"
  if [ -z "${merges}" ]; then
    echo "FAIL: ${test_name} — the ours-resolved merge commit was never pushed"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix 2>/dev/null
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# High-severity logic-error regression: the target branch fast-forwards
# again between the point the agent merged it (T1) and post-fix.src.sh's own
# fresh fetch of the target (T2, force-fetched by fetch_trusted_target_sha).
# The replay-skip must not require the *current* T2 to be an ancestor of
# HEAD — the agent only ever saw and merged T1. Requiring T2 in HEAD would
# bounce this legitimate merge into the default rebase, dropping it.
run_push_forge_conflict_merge_survives_target_advance_test() {
  local test_name="push-forge-conflict-merge-survives-target-advance"
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

  # T1: the target tip the agent actually sees and merges.
  git -C "${base}/seed" checkout -q main
  echo "ahead-1" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead 1"
  git -C "${base}/seed" push -q origin main
  local main_t1
  main_t1="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" merge -q --no-edit origin/main
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  # T2: the target fast-forwards again *after* the agent's merge, during the
  # window between pre-fix.src.sh's fetch and post-fix.src.sh's own fetch.
  git -C "${base}/seed" checkout -q main
  echo "ahead-2" > "${base}/seed/other2.txt"
  git -C "${base}/seed" add other2.txt
  git -C "${base}/seed" commit -q -m "main ahead 2"
  git -C "${base}/seed" push -q origin main

  write_merged_target_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix_with_mergeable "CONFLICTING" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "via a forge-conflict merge" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH even though the target (T2) advanced past what the agent merged (T1)"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${main_t1}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch does not contain T1, the target commit the agent actually merged"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local parents
  parents="$(git --git-dir="${base}/remote.git" rev-list --max-count=20 --merges refs/heads/agent/99-test-fix)"
  if [ -z "${parents}" ]; then
    echo "FAIL: ${test_name} — merge commit was dropped by replay"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  # The target's further advance (main ahead 2, pushed above) is deliberately
  # not required on the pushed branch: the regression under test is that the
  # replay-skip must not *demand* the current target tip in HEAD, not that
  # the PR should contain it.
  echo "PASS: ${test_name}"
}

run_push_preserves_forge_conflict_rebase_test() {
  local test_name="push-preserves-forge-conflict-rebase"
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

  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "bot",
  "actions": [
    {"type": "fix", "finding": "forge merge conflict", "description": "Rebased onto origin/main."}
  ],
  "summary": "Rebased onto main to resolve forge-reported conflict.",
  "tests_passed": true,
  "files_changed": ["file.txt"],
  "rebased_onto_target": true,
  "conflict_update": {
    "forge_state": "CONFLICTING",
    "target_branch": "main",
    "strategy": "rebase",
    "outcome": "rebased"
  }
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  # The rebased_onto_target arm now also requires
  # history_rewrite_preserves_remote_human_commits, which fails closed when
  # no bot git identity is available. Set GIT_BOT_EMAIL explicitly (matching
  # the squash/redo and merged_target-fallback tests' convention) so "pr A"
  # is recognized as a non-agent commit needing (and passing, via the
  # patch-id fallback) a preservation check, rather than depending on
  # whatever GIT_COMMITTER_EMAIL happens to be ambient in the calling shell.
  local bot_email="bot@example.com"
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix_with_mergeable "CONFLICTING" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" "" "rebase" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "after a forge-conflict rebase" "${stdout_log}"; then
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
  echo "PASS: ${test_name}"
}

# High-severity finding: the rebase-skip must not fire on the sandbox-written
# rebased_onto_target flag alone when the runner-computed strategy is the
# conservative default "merge" and no human explicitly asked for a rebase.
# Same fixture as run_push_preserves_forge_conflict_rebase_test, but without
# a "rebase" strategy override — the skip must not fire, so the replay onto
# the stale remote PR tip (origin/BRANCH) proceeds and the new main tip is
# NOT what the pushed branch ends up based on.
run_push_forge_conflict_rebase_requires_strategy_test() {
  local test_name="push-forge-conflict-rebase-requires-strategy"
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
  local remote_pr_tip
  remote_pr_tip="$(git -C "${base}/seed" rev-parse HEAD)"

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

  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "bot",
  "actions": [
    {"type": "fix", "finding": "forge merge conflict", "description": "Rebased onto origin/main."}
  ],
  "summary": "Rebased onto main to resolve forge-reported conflict.",
  "tests_passed": true,
  "files_changed": ["file.txt"],
  "rebased_onto_target": true,
  "conflict_update": {
    "forge_state": "CONFLICTING",
    "target_branch": "main",
    "strategy": "rebase",
    "outcome": "rebased"
  }
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  # No conflict_strategy override — FIX_CONFLICT_UPDATE_STRATEGY stays unset,
  # so the runner computes the default "merge" strategy despite the sandbox
  # having recorded rebased_onto_target:true.
  run_push_rebase_postfix_with_mergeable "CONFLICTING" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "after a forge-conflict rebase" "${stdout_log}"; then
    echo "FAIL: ${test_name} — strategy=merge must not authorize the rebase-skip"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${main_ahead}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch should not be based on the new main tip without strategy=rebase"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${remote_pr_tip}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch does not replay onto the stale remote PR tip"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# High-severity auth-bypass finding: REBASE_TARGET_ANCESTOR_OK
# (merge-base(HEAD, TRUSTED_TARGET_SHA) is an ancestor of HEAD) is
# near-tautological for related histories — by its own comment it only fails
# for genuinely unrelated histories — so it does not prove HEAD still
# contains the PR's own commits. Simulate a sandbox that resets HEAD onto the
# bare target tip (dropping "real A" entirely, unlike a genuine rebase which
# would preserve its patch-id) and then adds a tree-changing follow-up
# commit, while still claiming rebased_onto_target:true with strategy=rebase.
# Without requiring history_rewrite_preserves_remote_human_commits, every
# other conjunct in the rebased_onto_target arm is satisfied and the run
# would force-with-lease push local HEAD, permanently dropping "real A" from
# the remote. With the fix, the preservation check fails (no ancestor,
# tree, or patch-id match for "real A" in target..HEAD), so the skip must
# not fire — the run falls through to the safe fetch+rebase replay onto
# origin/${BRANCH}, which still preserves "real A" because it becomes the
# new base.
run_push_forge_conflict_rebased_onto_target_requires_preservation_test() {
  local test_name="push-forge-conflict-rebased-onto-target-requires-preservation"
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

  # A confused or compromised sandbox resets onto the bare target tip
  # (dropping "real A") instead of genuinely rebasing onto it, then adds a
  # follow-up commit that touches a different file so the safe fallthrough
  # rebase replay (asserted below) applies cleanly with no conflict.
  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" reset -q --hard origin/main
  echo "fixed" > "${base}/repo/followup.txt"
  git -C "${base}/repo" add followup.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "bot",
  "actions": [
    {"type": "fix", "finding": "forge merge conflict", "description": "Rebased onto origin/main."}
  ],
  "summary": "Rebased onto main to resolve forge-reported conflict.",
  "tests_passed": true,
  "files_changed": ["followup.txt"],
  "rebased_onto_target": true,
  "conflict_update": {
    "forge_state": "CONFLICTING",
    "target_branch": "main",
    "strategy": "rebase",
    "outcome": "rebased"
  }
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  # GIT_BOT_EMAIL set explicitly, matching the other preservation tests, so
  # "real A" (author "Test") is recognized as a non-agent commit needing a
  # preservation check rather than depending on ambient shell state.
  local bot_email="bot@example.com"
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix_with_mergeable "CONFLICTING" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" "" "rebase" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "after a forge-conflict rebase" "${stdout_log}"; then
    echo "FAIL: ${test_name} — rebase-skip fired without proving real A's commit was preserved"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch is missing the PR's own commit (real A) — it was dropped"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Low-severity missing-test finding: rebase-side counterpart of
# run_push_forge_conflict_merge_survives_target_advance_test above.
# REBASE_TARGET_ANCESTOR_OK only requires merge-base(HEAD, TRUSTED_TARGET_SHA)
# to be an ancestor of HEAD, which tolerates the target having advanced
# further (to T2) after the agent actually rebased onto T1. The skip must
# still fire and publish the rebase rather than bouncing into the default
# `git rebase origin/${BRANCH}`, which would replay the agent's rebased
# commits onto the stale remote PR tip and undo the conflict resolution.
run_push_forge_conflict_rebase_survives_target_advance_test() {
  local test_name="push-forge-conflict-rebase-survives-target-advance"
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

  # T1: the target tip the agent actually sees and rebases onto.
  git -C "${base}/seed" checkout -q main
  echo "ahead-1" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead 1"
  git -C "${base}/seed" push -q origin main
  local main_t1
  main_t1="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" rebase -q origin/main
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  # T2: the target fast-forwards again *after* the agent's rebase, during the
  # window between pre-fix.src.sh's fetch and post-fix.src.sh's own fetch.
  git -C "${base}/seed" checkout -q main
  echo "ahead-2" > "${base}/seed/other2.txt"
  git -C "${base}/seed" add other2.txt
  git -C "${base}/seed" commit -q -m "main ahead 2"
  git -C "${base}/seed" push -q origin main

  mkdir -p "${base}/iteration-1/output"
  cat > "${base}/iteration-1/output/agent-result.json" <<'JSONEOF'
{
  "pr_number": 99,
  "trigger_source": "bot",
  "actions": [
    {"type": "fix", "finding": "forge merge conflict", "description": "Rebased onto origin/main."}
  ],
  "summary": "Rebased onto main to resolve forge-reported conflict.",
  "tests_passed": true,
  "files_changed": ["file.txt"],
  "rebased_onto_target": true,
  "conflict_update": {
    "forge_state": "CONFLICTING",
    "target_branch": "main",
    "strategy": "rebase",
    "outcome": "rebased"
  }
}
JSONEOF

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  # GIT_BOT_EMAIL set explicitly (see the sibling preservation test above) so
  # "pr A" (author "Test") passes history_rewrite_preserves_remote_human_commits
  # via the patch-id fallback, a genuine rebase having reapplied its patch.
  local bot_email="bot@example.com"
  GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix_with_mergeable "CONFLICTING" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" "" "rebase" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "after a forge-conflict rebase" "${stdout_log}"; then
    echo "FAIL: ${test_name} — expected skip of rebase onto origin/BRANCH even though the target (T2) advanced past what the agent rebased onto (T1)"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${main_t1}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch does not contain T1, the target commit the agent actually rebased onto"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  # The target's further advance (main ahead 2, pushed above) is deliberately
  # not required on the pushed branch: the regression under test is that the
  # replay-skip must not *demand* the current target tip in HEAD, not that
  # the PR should contain it.
  echo "PASS: ${test_name}"
}

# High-severity finding: merged_target must not skip replay on target-SHA
# ancestry alone. A GitLab-reconstruction-style local history (built fresh
# from origin/main, never derived from the real remote agent branch) can
# trivially satisfy "target SHA is an ancestor of HEAD" without ever
# containing the real remote PR tip's commits. Requiring origin/${BRANCH}
# to also be an ancestor of HEAD before skipping must catch this — instead
# the run falls through to the ordinary fetch+rebase path, which preserves
# the real remote commit.
run_push_forge_conflict_merge_requires_branch_ancestry_test() {
  local test_name="push-forge-conflict-merge-requires-branch-ancestry"
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

  # Reconstructed from origin/main directly — never derived from the real
  # remote agent/99-test-fix branch, so origin/${BRANCH} is not an ancestor.
  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -B agent/99-test-fix origin/main
  echo "pr-a" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  write_merged_target_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix_with_mergeable "CONFLICTING" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "via a forge-conflict merge" "${stdout_log}"; then
    echo "FAIL: ${test_name} — merged_target skip fired without origin/BRANCH ancestry"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — real remote commit was dropped by the push"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Medium-severity finding: the origin/${BRANCH}-ancestor requirement above
# (needed to stop merged_target from authorizing a force-push over real
# remote commits — see the test above) can never be satisfied by a genuine
# GitLab reconstruction: the sandbox rebuilds BRANCH from API content with
# new SHAs, so even a real forge-conflict merge with equivalent content
# never descends from origin/${BRANCH}'s real SHAs. PRE_AGENT_HEAD is set by
# the runner before the sandbox ever ran, so it is not sandbox-influenceable;
# when the freshly-fetched origin/${BRANCH} is unchanged since then, nobody
# pushed anything new to the remote branch during the run and the merge
# commit is safe to preserve as-is. This asserts the fallback fires and the
# pushed tip is still a real merge commit, not flattened by a default rebase.
run_push_forge_conflict_merge_reconstruction_preserves_merge_test() {
  local test_name="push-forge-conflict-merge-reconstruction-preserves-merge"
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
  local base_sha
  base_sha="$(git -C "${base}/seed" rev-parse HEAD)"

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/agenta.txt"
  git -C "${base}/seed" add agenta.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/otherfile.txt"
  git -C "${base}/seed" add otherfile.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main

  # Reconstructed from the PR's fork point (base_sha), not from the real
  # remote agent branch — the GitLab sandbox cannot fetch that branch, so it
  # rebuilds it via API-applied diffs, producing a content-equivalent commit
  # with a brand new SHA. origin/${BRANCH} (real_a) is therefore never an
  # ancestor of the reconstruction. The sandbox then genuinely merges
  # origin/main (now ahead — the forge-conflict resolution) and adds a fix
  # commit, matching what a real GitLab conflict-reconciliation run produces.
  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -B agent/99-test-fix "${base_sha}"
  echo "pr-a" > "${base}/repo/agenta.txt"
  git -C "${base}/repo" add agenta.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  git -C "${base}/repo" merge -q --no-edit origin/main
  echo "fixed" > "${base}/repo/fixfile.txt"
  git -C "${base}/repo" add fixfile.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  write_merged_target_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  # PRE_AGENT_HEAD is the real remote branch tip as of pre-fix time — since
  # origin/agent/99-test-fix (real_a) has not moved since, the fallback
  # should treat this as safe to preserve. The fallback's content-preservation
  # guard (history_rewrite_preserves_remote_human_commits) fails closed when
  # no bot git identity is available, so — unlike run_push_rebase_postfix's
  # own default of forwarding whatever GIT_BOT_EMAIL happens to be ambient —
  # set one explicitly here, matching the squash/redo tests' convention, so
  # this test doesn't depend on the calling shell's environment.
  local bot_email="bot@example.com"
  PRE_AGENT_HEAD="${real_a}" \
    GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix_gitlab_with_mergeable "conflict" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review_bot" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "GitLab reconstruction detected" "${stdout_log}"; then
    echo "FAIL: ${test_name} — reconstruction fallback did not fire"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local pushed_tip merge_count
  pushed_tip="$(git --git-dir="${base}/remote.git" rev-parse refs/heads/agent/99-test-fix)"
  merge_count="$(git --git-dir="${base}/remote.git" rev-list --min-parents=2 --count "${pushed_tip}")"
  if [ "${merge_count}" = "0" ]; then
    echo "FAIL: ${test_name} — pushed history has no merge commit; the forge-conflict resolution was dropped"
    git --git-dir="${base}/remote.git" log --oneline --graph refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" cat-file -e "${pushed_tip}:otherfile.txt" 2>/dev/null; then
    echo "FAIL: ${test_name} — target content brought in by the merge (otherfile.txt) is missing from the pushed tree"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Negative counterpart to the reconstruction test above: if a human pushes a
# new real commit to the remote branch after PRE_AGENT_HEAD was captured but
# before this post-script runs, origin/${BRANCH} no longer matches
# PRE_AGENT_HEAD. The fallback must not fire in that case — falling through
# to the ordinary fetch+rebase path is what preserves the new human commit.
run_push_forge_conflict_merge_reconstruction_requires_unchanged_branch_test() {
  local test_name="push-forge-conflict-merge-reconstruction-requires-unchanged-branch"
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
  local base_sha
  base_sha="$(git -C "${base}/seed" rev-parse HEAD)"

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/agenta.txt"
  git -C "${base}/seed" add agenta.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/otherfile.txt"
  git -C "${base}/seed" add otherfile.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main

  # A human pushes a further real commit to the PR branch after PRE_AGENT_HEAD
  # (real_a) was captured — origin/${BRANCH} has now advanced past it.
  git -C "${base}/seed" checkout -q agent/99-test-fix
  echo "human-follow-up" > "${base}/seed/humanfile.txt"
  git -C "${base}/seed" add humanfile.txt
  git -C "${base}/seed" commit -q -m "human follow-up"
  git -C "${base}/seed" push -q origin agent/99-test-fix
  local real_b
  real_b="$(git -C "${base}/seed" rev-parse HEAD)"

  # Sandbox reconstruction still only knows about the fork point + real A (it
  # started before the human follow-up commit existed) and separately merges
  # in the (reconstructed) target branch.
  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -B agent/99-test-fix "${base_sha}"
  echo "pr-a" > "${base}/repo/agenta.txt"
  git -C "${base}/repo" add agenta.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  git -C "${base}/repo" merge -q --no-edit origin/main
  echo "fixed" > "${base}/repo/fixfile.txt"
  git -C "${base}/repo" add fixfile.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  write_merged_target_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  PRE_AGENT_HEAD="${real_a}" \
    run_push_rebase_postfix_gitlab_with_mergeable "conflict" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review_bot" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "GitLab reconstruction detected" "${stdout_log}"; then
    echo "FAIL: ${test_name} — reconstruction fallback fired despite origin/BRANCH advancing past PRE_AGENT_HEAD"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_b}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — the human follow-up commit was dropped by the push"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Medium-severity (auth-bypass) finding: the merged_target / GitLab-
# reconstruction fallback trusts history_rewrite_preserves_remote_human_commits,
# but that helper also tolerates a genuine rebase via its same-author +
# same-patch-id fallback — the exact operation the sibling rebased_onto_target
# arm requires FIX_CONFLICT_STRATEGY=rebase or a human rebase request for. A
# confused or compromised bot-triggered agent could actually rebase onto the
# target instead of merging, falsely report merged_target:true, and still
# satisfy the fallback via patch-id alone. Simulate that: the agent's own
# branch is genuinely rebased onto the (now-ahead) target, changing its
# commit's SHA and tree but preserving its patch-id, then a fix commit is
# added. origin/${BRANCH} (the real, unchanged remote PR tip) is therefore no
# longer an ancestor of HEAD (a rebase discards the original commit object),
# so only the patch-id fallback can recognize it — HISTORY_REWRITE_PATCH_ID_ONLY_MATCH
# must come back true, and with no human rebase request the fallback must not
# fire. The safe fallthrough (fetch+rebase replay onto origin/${BRANCH}) still
# preserves every commit's content without needing --force-with-lease, so
# nothing is lost — this only proves the *fallback itself* did not
# authorize an unreviewed history rewrite.
run_push_forge_conflict_merged_target_requires_rebase_authorization_test() {
  local test_name="push-forge-conflict-merged-target-requires-rebase-authorization"
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

  # The agent secretly rebases (not merges) onto the now-ahead target, then
  # adds its fix commit. This is real history (not a GitLab-reconstruction
  # SHA change), but the effect on ancestry/patch-id is the same: real_a's
  # commit object is gone, replaced by one with the same patch-id but a
  # different tree (it now sits on top of "main ahead").
  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" rebase -q origin/main
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  write_merged_target_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  # gitlab forge (so the fallback's forge gate does not itself account for
  # the whole test), bot trigger, no human instruction, default (merge)
  # strategy, PRE_AGENT_HEAD unchanged — every other condition of the
  # fallback is satisfied; only the patch-id-only authorization gap is
  # under test here. GIT_BOT_EMAIL is set explicitly (see the
  # reconstruction-preserves-merge test's comment above) so
  # history_rewrite_preserves_remote_human_commits treats "real A" as a
  # non-agent commit needing a preservation check, regardless of whatever
  # GIT_COMMITTER_EMAIL happens to be ambient in the calling shell.
  local bot_email="bot@example.com"
  PRE_AGENT_HEAD="${real_a}" \
    GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix_gitlab_with_mergeable "conflict" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review_bot" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "GitLab reconstruction detected" "${stdout_log}"; then
    echo "FAIL: ${test_name} — merged_target fallback fired on a disguised rebase with no human rebase authorization"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch is not a descendant of the real remote PR tip"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  # The safe fallthrough replays onto origin/${BRANCH} via a fresh
  # `git rebase`, which re-creates "main ahead" with a new SHA (it's being
  # cherry-picked, not fast-forwarded) — so its *content* survives even
  # though the original main_ahead commit object does not. Check the file
  # it introduced rather than the original SHA's ancestry.
  if ! git --git-dir="${base}/remote.git" cat-file -e \
       "refs/heads/agent/99-test-fix:other.txt" 2>/dev/null; then
    echo "FAIL: ${test_name} — pushed branch is missing the target content brought in by the (disguised) rebase"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Medium-severity logic-error finding: history_rewrite_preserves_remote_human_commits
# only proves origin/${BRANCH}'s own commits survive in HEAD — it says nothing
# about whether the target's content was ever actually incorporated. Simulate
# a GitLab reconstruction that faithfully recreates the original PR branch
# (so the preservation check passes) but never merges the target at all — no
# merge commit exists anywhere in the resulting history, so the forge
# conflict is never actually resolved. Without requiring MERGE_TARGET_ANCESTOR_OK,
# every other conjunct of the reconstruction fallback is satisfied and it
# would fire, force-pushing a branch that is still CONFLICTING against the
# target on the remote. With the fix, the fallback must not fire; the run
# falls through to the safe fetch+rebase replay, which still preserves
# "real A" (nothing is lost, the conflict is simply left unresolved for the
# ordinary flow to handle on a later run).
run_push_forge_conflict_merged_target_reconstruction_requires_actual_merge_test() {
  local test_name="push-forge-conflict-merged-target-reconstruction-requires-actual-merge"
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
  local base_sha
  base_sha="$(git -C "${base}/seed" rev-parse HEAD)"

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/agenta.txt"
  git -C "${base}/seed" add agenta.txt
  git -C "${base}/seed" commit -q -m "real A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local real_a
  real_a="$(git -C "${base}/seed" rev-parse HEAD)"

  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/otherfile.txt"
  git -C "${base}/seed" add otherfile.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main

  # Reconstruction faithfully recreates the original PR branch content from
  # the fork point (so history_rewrite_preserves_remote_human_commits would
  # pass), but never merges origin/main — no merge commit anywhere in the
  # resulting history.
  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q -B agent/99-test-fix "${base_sha}"
  echo "pr-a" > "${base}/repo/agenta.txt"
  git -C "${base}/repo" add agenta.txt
  git -C "${base}/repo" commit -q -m "reconstructed A"
  echo "fixed" > "${base}/repo/fixfile.txt"
  git -C "${base}/repo" add fixfile.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  write_merged_target_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  local bot_email="bot@example.com"
  PRE_AGENT_HEAD="${real_a}" \
    GIT_BOT_EMAIL="${bot_email}" \
    run_push_rebase_postfix_gitlab_with_mergeable "conflict" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review_bot" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "GitLab reconstruction detected" "${stdout_log}"; then
    echo "FAIL: ${test_name} — reconstruction fallback fired despite no merge commit ever incorporating the target"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${real_a}" refs/heads/agent/99-test-fix; then
    echo "FAIL: ${test_name} — pushed branch is missing the PR's own commit (real A) — it was dropped"
    git --git-dir="${base}/remote.git" log --oneline refs/heads/agent/99-test-fix
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Medium-severity finding: a forge-conflict merge's second parent (historical
# target-branch commits) must stay out of scope for the pre-commit gate's
# autofix re-scan, not just the initial authoritative gitleaks scan. Section 1
# already scopes GITLEAKS_LOG_OPTS to --first-parent when a merge is in range;
# this test drives the gate into its autofix retry (a mock pre-commit hook
# that "reformats" a file and fails once) and verifies the re-scan inside
# precommit_run_gate also uses that first-parent-scoped range instead of the
# raw two-dot SCAN_RANGE, by planting a "secret" commit that only exists on
# the merge's second parent (main) and asserting it is never seen.
run_push_forge_conflict_precommit_gate_first_parent_test() {
  local test_name="push-forge-conflict-precommit-gate-first-parent"
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
  echo "repos: []" > "${base}/seed/.pre-commit-config.yaml"
  git -C "${base}/seed" add file.txt .pre-commit-config.yaml
  git -C "${base}/seed" commit -q -m "pr A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local pr_a_sha
  pr_a_sha="$(git -C "${base}/seed" rev-parse HEAD)"

  # A commit that only ever lands on main (the merge's second parent) —
  # stands in for a gitleaks-detectable secret in historical target-branch
  # history that this PR never touched.
  git -C "${base}/seed" checkout -q main
  echo "sekrit" > "${base}/seed/secret.txt"
  git -C "${base}/seed" add secret.txt
  git -C "${base}/seed" commit -q -m "main: historical secret"
  git -C "${base}/seed" push -q origin main
  local main_secret_sha
  main_secret_sha="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" merge -q --no-edit origin/main
  echo "fixed" > "${base}/repo/file.txt"
  git -C "${base}/repo" add file.txt
  git -C "${base}/repo" commit -q -m "fix: agent change"

  local gate_mock="${PUSH_REBASE_TMPDIR}/bin-precommit-gate"
  mkdir -p "${gate_mock}"
  cp "${PUSH_REBASE_MOCK_BIN}/sleep" "${gate_mock}/sleep"
  cp "${PUSH_REBASE_MOCK_BIN}/gh" "${gate_mock}/gh"
  cp "${PUSH_REBASE_MOCK_BIN}/git" "${gate_mock}/git"

  # Fails secret-detection if the given --log-opts range still reaches the
  # historical main-only commit (the caller forgot to scope the range to
  # --first-parent), or if a --pipe follow-up scan is fed the planted
  # target-branch secret's own content ("sekrit", from secret.txt above) —
  # i.e. the per-merge scan used a pairwise `-m --first-parent` diff instead
  # of the combined/resolution-only diff, dumping the whole incoming-target
  # tree delta rather than just the conflict resolution.
  cat > "${gate_mock}/gitleaks" <<EOF
#!/usr/bin/env bash
if [ "\$1" = version ]; then echo 8.30.1; exit 0; fi
log_opts=""
pipe_mode=false
for arg in "\$@"; do
  case "\${arg}" in
    --log-opts=*) log_opts="\${arg#--log-opts=}" ;;
    --pipe) pipe_mode=true ;;
  esac
done
if [ -n "\${log_opts}" ] \\
   && git log \${log_opts} --format=%H 2>/dev/null | grep -qx "${main_secret_sha}"; then
  echo "leaks found: historical target-branch commit ${main_secret_sha} in scan range" >&2
  exit 1
fi
if \${pipe_mode}; then
  pipe_input="\$(cat)"
  if printf '%s' "\${pipe_input}" | grep -q "sekrit"; then
    echo "leaks found: historical target-branch secret content in --pipe merge diff" >&2
    exit 1
  fi
fi
exit 0
EOF
  chmod +x "${gate_mock}/gitleaks"

  # Simulates an auto-fixing hook: fails and rewrites a tracked file on its
  # first run (driving precommit_run_gate into its autofix-amend-rescan
  # path), then reports clean on the retry.
  cat > "${gate_mock}/pre-commit" <<EOF
#!/usr/bin/env bash
marker="${base}/.precommit-ran-marker"
if [ ! -f "\${marker}" ]; then
  touch "\${marker}"
  echo "autofixed" > file.txt
  echo "hook modified files"
  exit 1
fi
echo "all hooks passed"
exit 0
EOF
  chmod +x "${gate_mock}/pre-commit"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  PRE_AGENT_HEAD="${pr_a_sha}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${gate_mock}" \
    "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "leaks found" "${stdout_log}"; then
    echo "FAIL: ${test_name} — autofix re-scan walked the merge's second parent"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "hook modified files" "${stdout_log}"; then
    echo "FAIL: ${test_name} — mock pre-commit never drove the autofix retry path"
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
  if git --git-dir="${base}/remote.git" merge-base --is-ancestor \
       "${main_secret_sha}" "${pr_a_sha}" 2>/dev/null; then
    echo "FAIL: ${test_name} — test fixture invalid: secret commit is an ancestor of pr A"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_push_forge_conflict_untrusted_merge_secret_test() {
  local test_name="push-forge-conflict-untrusted-merge-secret"
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
  local pr_a_sha
  pr_a_sha="$(git -C "${base}/seed" rev-parse HEAD)"

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix

  # Simulate a compromised agent session creating a *different*, untrusted
  # merge during the same run: a throwaway branch off main that cleanly adds
  # a new file (no conflict with file.txt) containing a gitleaks-detectable
  # string. Its tip is never pushed to origin/main, so it is not part of
  # trusted target-branch history — the authoritative scan must not trust a
  # combined (--cc) diff for this merge, since --cc omits any path whose
  # merge-result blob matches either parent (secret.txt matches parent 2
  # exactly and never conflicts with file.txt).
  git -C "${base}/repo" checkout -q -b evil-throwaway origin/main
  echo "sekrit" > "${base}/repo/secret.txt"
  git -C "${base}/repo" add secret.txt
  git -C "${base}/repo" commit -q -m "evil: planted secret"

  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" merge -q --no-edit evil-throwaway

  local gate_mock="${PUSH_REBASE_TMPDIR}/bin-untrusted-merge-secret"
  mkdir -p "${gate_mock}"
  cp "${PUSH_REBASE_MOCK_BIN}/sleep" "${gate_mock}/sleep"
  cp "${PUSH_REBASE_MOCK_BIN}/gh" "${gate_mock}/gh"
  cp "${PUSH_REBASE_MOCK_BIN}/git" "${gate_mock}/git"

  # Only fails a --pipe scan whose content contains the planted secret. A
  # combined (--cc) diff of this merge would omit secret.txt entirely, so
  # this mock only catches a regression if the per-merge scan falls back to
  # the full pairwise first-parent diff for a merge whose second parent is
  # not confirmed trusted-target history.
  cat > "${gate_mock}/gitleaks" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then echo 8.30.1; exit 0; fi
pipe_mode=false
for arg in "$@"; do
  case "${arg}" in
    --pipe) pipe_mode=true ;;
  esac
done
if ${pipe_mode}; then
  pipe_input="$(cat)"
  if printf '%s' "${pipe_input}" | grep -q "sekrit"; then
    echo "leaks found: planted secret in untrusted merge diff" >&2
    exit 1
  fi
fi
exit 0
EOF
  chmod +x "${gate_mock}/gitleaks"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  PRE_AGENT_HEAD="${pr_a_sha}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${gate_mock}" \
    "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — push succeeded; planted secret in the untrusted merge was not detected"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "leaks found" "${stdout_log}"; then
    echo "FAIL: ${test_name} — failed for a reason other than the planted secret"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# High-severity finding: the second-parent-only trust check is incomplete for
# a merge with more than two parents (an octopus merge). Combined (--cc) diff
# omits any path whose merge-result blob matches ANY parent, not just the one
# checked — a three-parent merge whose second parent is the trusted target
# and whose THIRD parent cleanly adds a secret file (no conflict) would pass
# the old parent-2-only check, select --cc, and never surface the
# third-parent-only file, since its blob matches parent 3 exactly and is
# therefore "uninteresting" to the combined diff. Every non-first parent must
# be confirmed trusted before --cc is used.
run_push_forge_conflict_untrusted_octopus_merge_secret_test() {
  local test_name="push-forge-conflict-untrusted-octopus-merge-secret"
  local base="${PUSH_REBASE_TMPDIR}/${test_name}"
  mkdir -p "${base}"

  git init -q --bare -b main "${base}/remote.git"
  git init -q -b main "${base}/seed"
  push_rebase_ident "${base}/seed"
  echo "base" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "init"
  local base_sha
  base_sha="$(git -C "${base}/seed" rev-parse HEAD)"
  git -C "${base}/seed" remote add origin "${base}/remote.git"
  git -C "${base}/seed" push -q -u origin main

  git -C "${base}/seed" checkout -q -b agent/99-test-fix
  echo "pr-a" > "${base}/seed/file.txt"
  git -C "${base}/seed" add file.txt
  git -C "${base}/seed" commit -q -m "pr A"
  git -C "${base}/seed" push -q -u origin agent/99-test-fix
  local pr_a_sha
  pr_a_sha="$(git -C "${base}/seed" rev-parse HEAD)"

  # main must actually advance past the agent branch's fork point — otherwise
  # merging origin/main into the agent branch is a no-op fast-forward (it's
  # already an ancestor) and `git merge` collapses to a plain 2-parent merge
  # of just the throwaway branch, not the 3-parent octopus this test needs.
  git -C "${base}/seed" checkout -q main
  echo "ahead" > "${base}/seed/other.txt"
  git -C "${base}/seed" add other.txt
  git -C "${base}/seed" commit -q -m "main ahead"
  git -C "${base}/seed" push -q origin main

  git clone -q "${base}/remote.git" "${base}/repo"
  push_rebase_ident "${base}/repo"
  git -C "${base}/repo" checkout -q agent/99-test-fix

  # Untrusted third parent: a throwaway branch off the ORIGINAL base commit
  # (not origin/main) that cleanly adds a new file (no conflict with anything
  # else being merged) containing a gitleaks-detectable string. Branching off
  # origin/main instead would make origin/main an ancestor of this branch, and
  # git's octopus merge silently drops any merge head that is already an
  # ancestor of another one — collapsing this back to a 2-parent merge. Never
  # pushed to origin/main, so this branch is not trusted target-branch history.
  git -C "${base}/repo" checkout -q -b evil-throwaway "${base_sha}"
  echo "sekrit" > "${base}/repo/secret.txt"
  git -C "${base}/repo" add secret.txt
  git -C "${base}/repo" commit -q -m "evil: planted secret"

  # Octopus merge: parent 2 (origin/main) IS trusted target history — the old
  # code only checked this parent and would trust --cc — but parent 3
  # (evil-throwaway) is not. `git merge` accepts multiple branches at once
  # and creates a single multi-parent commit when none of them conflict.
  git -C "${base}/repo" checkout -q agent/99-test-fix
  git -C "${base}/repo" merge -q --no-edit origin/main evil-throwaway
  local merge_parent_count
  merge_parent_count="$(git -C "${base}/repo" log -1 --format='%P' HEAD | wc -w | tr -d ' ')"
  if [ "${merge_parent_count}" != "3" ]; then
    echo "FAIL: ${test_name} — fixture setup did not produce a 3-parent merge (got ${merge_parent_count} parents)"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local gate_mock="${PUSH_REBASE_TMPDIR}/bin-untrusted-octopus-merge-secret"
  mkdir -p "${gate_mock}"
  cp "${PUSH_REBASE_MOCK_BIN}/sleep" "${gate_mock}/sleep"
  cp "${PUSH_REBASE_MOCK_BIN}/gh" "${gate_mock}/gh"
  cp "${PUSH_REBASE_MOCK_BIN}/git" "${gate_mock}/git"

  # Only fails a --pipe scan whose content contains the planted secret. A
  # combined (--cc) diff of this merge would omit secret.txt entirely (it
  # matches parent 3 exactly), so this mock only catches a regression if the
  # per-merge scan falls back to the full pairwise first-parent diff for a
  # merge with an unconfirmed extra parent.
  cat > "${gate_mock}/gitleaks" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then echo 8.30.1; exit 0; fi
pipe_mode=false
for arg in "$@"; do
  case "${arg}" in
    --pipe) pipe_mode=true ;;
  esac
done
if ${pipe_mode}; then
  pipe_input="$(cat)"
  if printf '%s' "${pipe_input}" | grep -q "sekrit"; then
    echo "leaks found: planted secret in untrusted octopus merge diff" >&2
    exit 1
  fi
fi
exit 0
EOF
  chmod +x "${gate_mock}/gitleaks"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  PRE_AGENT_HEAD="${pr_a_sha}" \
    run_push_rebase_postfix "${base}" "${stdout_log}" "${gate_mock}" \
    "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -eq 0 ]; then
    echo "FAIL: ${test_name} — push succeeded; planted secret on the untrusted third parent was not detected"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "leaks found" "${stdout_log}"; then
    echo "FAIL: ${test_name} — failed for a reason other than the planted secret"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_push_blocked_mergeability_does_not_skip_test() {
  local test_name="push-blocked-mergeability-does-not-skip"
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

  write_merged_target_result "${base}/iteration-1/output"

  local stdout_log="${PUSH_REBASE_TMPDIR}/stdout-${test_name}.log"
  local exit_code=0
  run_push_rebase_postfix_with_mergeable "UNKNOWN" "${base}" "${stdout_log}" \
    "${PUSH_REBASE_MOCK_BIN}" "fullsend-ai-review[bot]" || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "via a forge-conflict merge" "${stdout_log}"; then
    echo "FAIL: ${test_name} — UNKNOWN mergeability triggered a conflict skip"
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
  echo "PASS: ${test_name}"
}

run_push_preserves_forge_conflict_merge_test
run_push_forge_conflict_merge_ours_resolution_no_diff_test
run_push_forge_conflict_merge_survives_target_advance_test
run_push_preserves_forge_conflict_rebase_test
run_push_forge_conflict_rebase_requires_strategy_test
run_push_forge_conflict_rebased_onto_target_requires_preservation_test
run_push_forge_conflict_rebase_survives_target_advance_test
run_push_forge_conflict_merge_requires_branch_ancestry_test
run_push_forge_conflict_merge_reconstruction_preserves_merge_test
run_push_forge_conflict_merge_reconstruction_requires_unchanged_branch_test
run_push_forge_conflict_merged_target_requires_rebase_authorization_test
run_push_forge_conflict_merged_target_reconstruction_requires_actual_merge_test
run_push_forge_conflict_precommit_gate_first_parent_test
run_push_forge_conflict_untrusted_merge_secret_test
run_push_forge_conflict_untrusted_octopus_merge_secret_test
run_push_blocked_mergeability_does_not_skip_test

rm -rf "${PUSH_REBASE_TMPDIR}"

# ---------------------------------------------------------------------------
# Per-PR automatic fix budget label (issue #1680)
# ---------------------------------------------------------------------------
FIX_BUDGET_TMPDIR="$(mktemp -d)"

# --- fix_budget_from_labels unit tests ---
run_fix_budget_parse_test() {
  local test_name="$1"
  local labels="$2"
  local bot_cap="$3"
  local expected="$4"
  local actual
  # shellcheck disable=SC2030,SC2031
  actual="$(
    FULLSEND_FORGE=github
    # shellcheck source=lib/fix-ops.lib.sh
    source "${SCRIPT_DIR}/lib/fix-ops.lib.sh"
    fix_budget_from_labels "${labels}" "${bot_cap}"
  )"
  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name} — expected '${expected}', got '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_fix_budget_parse_test "fix-budget-lowers-cap" $'bug\nfullsend-fix-budget/2' 5 "2"
run_fix_budget_parse_test "fix-budget-missing" $'bug\narea/api' 5 ""
run_fix_budget_parse_test "fix-budget-no-labels" "" 5 ""
run_fix_budget_parse_test "fix-budget-equal-to-cap-ignored" "fullsend-fix-budget/5" 5 ""
run_fix_budget_parse_test "fix-budget-above-cap-ignored" "fullsend-fix-budget/9" 5 ""
run_fix_budget_parse_test "fix-budget-zero-ignored" "fullsend-fix-budget/0" 5 ""
run_fix_budget_parse_test "fix-budget-negative-ignored" "fullsend-fix-budget/-1" 5 ""
run_fix_budget_parse_test "fix-budget-non-integer-ignored" "fullsend-fix-budget/two" 5 ""
run_fix_budget_parse_test "fix-budget-leading-zero-ignored" "fullsend-fix-budget/02" 5 ""
run_fix_budget_parse_test "fix-budget-trailing-text-ignored" "fullsend-fix-budget/2x" 5 ""
run_fix_budget_parse_test "fix-budget-oversized-ignored" "fullsend-fix-budget/18446744073709551616" 5 ""
run_fix_budget_parse_test "fix-budget-smallest-wins" $'fullsend-fix-budget/3\nfullsend-fix-budget/1\nfullsend-fix-budget/4' 5 "1"
run_fix_budget_parse_test "fix-budget-invalid-mixed-with-valid" $'fullsend-fix-budget/0\nfullsend-fix-budget/3' 5 "3"
run_fix_budget_parse_test "fix-budget-other-prefix-ignored" "my-fullsend-fix-budget/2" 5 ""

# --- Shared gh mock: --json labels returns GH_MOCK_LABELS (or fails when
# GH_MOCK_LABELS_FAIL is set); everything else is logged and succeeds with
# no output, so mergeability reads as "unknown" (no conflict path). ---
FIX_BUDGET_MOCK_BIN="${FIX_BUDGET_TMPDIR}/bin"
mkdir -p "${FIX_BUDGET_MOCK_BIN}"
cat > "${FIX_BUDGET_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALL_LOG:-/dev/null}"
if [[ "$*" == *"--json labels"* ]]; then
  if [ -n "${GH_MOCK_LABELS_FAIL:-}" ]; then
    exit 1
  fi
  [ -n "${GH_MOCK_LABELS:-}" ] && printf '%s\n' "${GH_MOCK_LABELS}"
fi
exit 0
MOCK
chmod +x "${FIX_BUDGET_MOCK_BIN}/gh"

# --- pre-fix enforcement ---
# run_prefix_budget_test NAME TRIGGER ITERATION LABELS EXPECT_EXIT EXPECT_TEXT [LABELS_FAIL]
run_prefix_budget_test() {
  local test_name="$1"
  local trigger="$2"
  local iteration="$3"
  local labels="$4"
  local expect_exit="$5"
  local expect_text="$6"
  local labels_fail="${7:-}"
  local base="${FIX_BUDGET_TMPDIR}/pre-${test_name}"
  mkdir -p "${base}/workspace" "${base}/home"
  local stdout_log="${base}/stdout.log"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    export PATH="${FIX_BUDGET_MOCK_BIN}:${PATH}"
    export HOME="${base}/home"
    export FULLSEND_FORGE="github"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_NUMBER="99"
    export TRIGGER_SOURCE="${trigger}"
    export FIX_ITERATION="${iteration}"
    export ITERATION_CAP="5"
    export ITERATION_CAP_HUMAN="10"
    export GITHUB_WORKSPACE="${base}/workspace"
    export GH_MOCK_LABELS="${labels}"
    export GH_MOCK_LABELS_FAIL="${labels_fail}"
    unset GITHUB_PATH
    bash "${PRE_SCRIPT}"
  ) > "${stdout_log}" 2>&1 || exit_code=$?

  if { [ "${expect_exit}" = "0" ] && [ "${exit_code}" -ne 0 ]; } \
     || { [ "${expect_exit}" != "0" ] && [ "${exit_code}" -eq 0 ]; }; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local line
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    if ! grep -qF -- "${line}" "${stdout_log}"; then
      echo "FAIL: ${test_name} — missing '${line}'"
      cat "${stdout_log}"
      FAILURES=$((FAILURES + 1))
      return
    fi
  done <<< "${expect_text}"
  echo "PASS: ${test_name}"
}

FB_BOT="fullsend-ai-review[bot]"

run_prefix_budget_test "prefix-budget-blocks-bot-above-label" \
  "${FB_BOT}" 3 $'area/api\nfullsend-fix-budget/2' 1 \
  $'exceeds the per-PR automatic fix budget of 2 set by label fullsend-fix-budget/2\nA human can still direct the agent with /fs-fix (up to 10 total iterations)'

run_prefix_budget_test "prefix-budget-allows-bot-at-label" \
  "${FB_BOT}" 2 "fullsend-fix-budget/2" 0 \
  $'lowers the automatic fix cap from 5 to 2\nFIX_ITERATION=2 of 2'

run_prefix_budget_test "prefix-budget-smallest-label-wins" \
  "${FB_BOT}" 2 $'fullsend-fix-budget/3\nfullsend-fix-budget/1' 1 \
  "set by label fullsend-fix-budget/1"

run_prefix_budget_test "prefix-budget-not-lower-than-cap-ignored" \
  "${FB_BOT}" 5 "fullsend-fix-budget/9" 0 \
  "FIX_ITERATION=5 of 5"

run_prefix_budget_test "prefix-budget-ignored-label-keeps-bot-cap-message" \
  "${FB_BOT}" 6 "fullsend-fix-budget/9" 1 \
  "exceeds bot cap of 5"

run_prefix_budget_test "prefix-budget-invalid-label-ignored" \
  "${FB_BOT}" 3 "fullsend-fix-budget/0" 0 \
  "FIX_ITERATION=3 of 5"

run_prefix_budget_test "prefix-budget-human-keeps-human-cap" \
  "alice" 3 "fullsend-fix-budget/2" 0 \
  "FIX_ITERATION=3 of 10"

run_prefix_budget_test "prefix-budget-label-read-failure-keeps-bot-cap" \
  "${FB_BOT}" 3 "fullsend-fix-budget/2" 0 \
  $'Could not read PR labels\nFIX_ITERATION=3 of 5' "1"

# GitLab: labels come from the MR API's labels array via curl.
run_prefix_budget_gitlab_test() {
  local test_name="prefix-budget-gitlab-blocks-bot-above-label"
  local base="${FIX_BUDGET_TMPDIR}/pre-${test_name}"
  mkdir -p "${base}/bin" "${base}/workspace" "${base}/home"
  cat > "${base}/bin/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"labels":["area::api","fullsend-fix-budget/2"],"target_branch":"main","detailed_merge_status":"mergeable"}'
MOCK
  chmod +x "${base}/bin/curl"
  local stdout_log="${base}/stdout.log"
  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    export PATH="${base}/bin:${PATH}"
    export HOME="${base}/home"
    export FULLSEND_FORGE="gitlab"
    export CI_SERVER_HOST="gitlab.com"
    export GITLAB_TOKEN="fake-token"
    export REPO_FULL_NAME="test-group/test-project"
    export PR_NUMBER="99"
    export PR_URL="https://gitlab.com/test-group/test-project/-/merge_requests/99"
    export TRIGGER_SOURCE="fullsend_review_bot"
    export FIX_ITERATION="3"
    export ITERATION_CAP="5"
    export ITERATION_CAP_HUMAN="10"
    export CI_PROJECT_DIR="${base}/workspace"
    bash "${PRE_SCRIPT}"
  ) > "${stdout_log}" 2>&1 || exit_code=$?
  if [ "${exit_code}" -eq 0 ] \
     || ! grep -qF "set by label fullsend-fix-budget/2" "${stdout_log}"; then
    echo "FAIL: ${test_name} — exit ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}
run_prefix_budget_gitlab_test

# --- post-fix needs-human label and summary ---
# A repo left on main makes post-fix take the NO_PUSH path, which still
# reaches the iteration-cap warning and summary.
# run_postfix_budget_test NAME TRIGGER ITERATION LABELS EXPECT_SUMMARY EXPECT_NEEDS_HUMAN
run_postfix_budget_test() {
  local test_name="$1"
  local trigger="$2"
  local iteration="$3"
  local labels="$4"
  local expect_summary="$5"
  local expect_needs_human="$6"
  local base="${FIX_BUDGET_TMPDIR}/post-${test_name}"
  mkdir -p "${base}/repo" "${base}/home"
  git init -q -b main "${base}/repo"
  git -C "${base}/repo" config user.email "test@example.com"
  git -C "${base}/repo" config user.name "Test"
  git -C "${base}/repo" commit --allow-empty -q -m "init"
  local gh_log="${base}/gh.log"
  : > "${gh_log}"
  local stdout_log="${base}/stdout.log"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${base}"
    export PATH="${FIX_BUDGET_MOCK_BIN}:${PATH}"
    export HOME="${base}/home"
    export GH_CALL_LOG="${gh_log}"
    export PUSH_TOKEN="fake-token"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_NUMBER="99"
    export TRIGGER_SOURCE="${trigger}"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="github"
    export FIX_ITERATION="${iteration}"
    export ITERATION_CAP="5"
    export ITERATION_CAP_HUMAN="10"
    export GH_MOCK_LABELS="${labels}"
    PRE_AGENT_HEAD="$(git -C "${base}/repo" rev-parse HEAD)"
    export PRE_AGENT_HEAD
    unset GITHUB_PATH FULLSEND_VALIDATED_ITERATION_DIR
    bash "${POST_SCRIPT}"
  ) > "${stdout_log}" 2>&1 || exit_code=$?

  if [ "${exit_code}" -ne 0 ]; then
    echo "FAIL: ${test_name} — exit ${exit_code}"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -qF -- "${expect_summary}" "${stdout_log}"; then
    echo "FAIL: ${test_name} — missing summary '${expect_summary}'"
    cat "${stdout_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local labelled="no"
  if grep -q -- '--add-label needs-human' "${gh_log}"; then
    labelled="yes"
  fi
  if [ "${labelled}" != "${expect_needs_human}" ]; then
    echo "FAIL: ${test_name} — needs-human applied: ${labelled}, expected: ${expect_needs_human}"
    cat "${gh_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_postfix_budget_test "postfix-budget-tightens-needs-human-and-summary" \
  "${FB_BOT}" 1 "fullsend-fix-budget/2" \
  "Iteration: 1 of 2 (bot cap, lowered by label fullsend-fix-budget/2)" "yes"

run_postfix_budget_test "postfix-budget-not-lower-than-cap-ignored" \
  "${FB_BOT}" 3 "fullsend-fix-budget/9" \
  "Iteration: 3 of 5 (bot cap)" "no"

run_postfix_budget_test "postfix-no-budget-keeps-bot-cap" \
  "${FB_BOT}" 3 "area/api" \
  "Iteration: 3 of 5 (bot cap)" "no"

run_postfix_budget_test "postfix-budget-human-keeps-human-cap" \
  "alice" 3 "fullsend-fix-budget/2" \
  "Iteration: 3 of 10 (human cap, total across bot+human)" "no"

rm -rf "${FIX_BUDGET_TMPDIR}"

# --- Summary ---

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
