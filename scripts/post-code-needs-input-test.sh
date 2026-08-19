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

REPO_FULL_NAME="owner/repo"
ISSUE_NUMBER="42"

# Mock gh: record every invocation to a log file. Most needs_input calls
# don't read gh's stdout, but the contract-violation guards (existing PR /
# default branch lookups) do, so this mock emulates those two responses via
# case-matching on the call — unlike post-triage-test.sh's mock, which
# emulates --body-file stdin capture and label-listing instead.
GH_LOG="${TMPDIR}/gh-calls.log"
MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/gh" <<MOCKEOF
#!/usr/bin/env bash
echo "gh \$*" >> "${GH_LOG}"
case "\$*" in
  *"repos/${REPO_FULL_NAME} --jq .default_branch"*)
    echo "main"
    ;;
  *"pr list --repo ${REPO_FULL_NAME} --head"*"--json url"*)
    echo "\${MOCK_EXISTING_PR_URL:-}"
    ;;
esac
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

# Mock gitleaks: post_needs_input_comment calls install_gitleaks then
# gitleaks detect. On CI runners where the real binary isn't pre-installed
# and install_gitleaks can't download it (network restrictions, missing
# deps), the scan would fail and the agent's explanation would be replaced
# with a generic placeholder — defeating the feature. A no-op mock (exit 0
# = no secrets found) ensures tests exercise the actual comment text path
# regardless of the host environment.
cat > "${MOCK_BIN}/gitleaks" <<'GLEOF'
#!/usr/bin/env bash
exit 0
GLEOF
chmod +x "${MOCK_BIN}/gitleaks"

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
    FULLSEND_FORGE="github" \
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
    FULLSEND_FORGE="github" \
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

# Like assert_log_pattern, but scoped to just the "gh issue comment" call —
# i.e. the actual posted comment body — rather than the whole gh call log
# (which also legitimately contains raw values like the branch name from
# earlier "gh pr list --head" lookup calls).
assert_comment_body_pattern() {
  local test_name="$1"
  local pattern="$2"
  local expect_present="$3"  # "yes" or "no"
  # The mocked gh call is logged as-is, including embedded newlines from a
  # multi-line --body value, so pull every line from the "gh issue comment"
  # call up to (not including) the next top-level "gh " invocation.
  local comment_line
  comment_line="$(awk '/^gh issue comment/{p=1} p && /^gh / && !/^gh issue comment/{exit} p' "${GH_LOG}")"

  if [ "${expect_present}" = "yes" ]; then
    if grep -qF -- "${pattern}" <<<"${comment_line}"; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name} — expected comment body pattern '${pattern}' not found"
      echo "Actual comment call: ${comment_line}"
      FAILURES=$((FAILURES + 1))
    fi
  else
    if grep -qF -- "${pattern}" <<<"${comment_line}"; then
      echo "FAIL: ${test_name} — expected comment body pattern '${pattern}' NOT to be found"
      echo "Actual comment call: ${comment_line}"
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

assert_log_pattern "needs-input-no-conflict-label-on-clean-path" \
  "fs-code-needs-input-conflict" "no"

assert_exit_code "needs-input-exits-zero" 0

# Regression guard: a result file without needs_input must not take the
# needs_input path at all. It's fine (and expected, per the test plan) for
# the script to fail further down since WORKDIR is not a git repo — only
# assert that none of the needs_input-specific gh calls happened.
run_post_code '{"target_branch":"main"}'

assert_log_pattern "no-needs-input-field-unaffected" \
  "fs-code-needs-input" "no"

# Regression guard: a needs_input longer than POST_FAILURE_DETAIL_MAX_LINES
# (default 30) must not be truncated from the start. sanitize_failure_detail
# defaults to tail-based truncation (recent lines of command/log output);
# needs_input is forward, human-authored prose and must be posted in full.
# Build the multi-line text with real newlines (not literal \n), then use
# jq to produce valid JSON with proper escaping.
NEEDS_INPUT_LONG_TEXT="opening context that must not be dropped"
for i in $(seq 1 35); do
  NEEDS_INPUT_LONG_TEXT="${NEEDS_INPUT_LONG_TEXT}
line ${i} of a long explanation"
done
FIXTURE_NEEDS_INPUT_LONG="$(jq -n --arg ni "${NEEDS_INPUT_LONG_TEXT}" '{target_branch:"main",needs_input:$ni}')"

run_post_code "${FIXTURE_NEEDS_INPUT_LONG}"

assert_log_pattern "needs-input-comment-not-truncated-from-start" \
  "opening context that must not be dropped" "yes"

# CODE_NEEDS_INPUT_LABEL env override
run_post_code_with_label "${FIXTURE_NEEDS_INPUT}" "custom-label"

assert_log_pattern "respects-code-needs-input-label-env-override" \
  "gh api repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels -f labels[]=custom-label --silent" "yes"

assert_log_pattern "respects-code-needs-input-label-env-override-no-default-label" \
  "labels[]=fs-code-needs-input" "no"

# --- Contract-violation guard tests ---
# needs_input should mean "stop before implementing" — no local commits, no
# open PR. Unlike the tests above (a plain, non-git WORKDIR so the guard's
# `git branch --show-current` is always empty and the guard is a no-op),
# these use a real git repo with a feature branch ahead of a fake
# `origin/main` ref, so the guard's checks actually run.
GIT_WORKDIR="${TMPDIR}/git-workdir"

setup_git_workdir_with_commits_ahead() {
  rm -rf "${GIT_WORKDIR}"
  git init -q -b main "${GIT_WORKDIR}"
  git -C "${GIT_WORKDIR}" config user.email "test@example.com"
  git -C "${GIT_WORKDIR}" config user.name "Test"
  git -C "${GIT_WORKDIR}" commit --allow-empty -m "init" -q
  # A local-only ref standing in for a fetched remote-tracking branch — no
  # actual remote needed for the guard's merge-base-style comparison.
  git -C "${GIT_WORKDIR}" update-ref refs/remotes/origin/main HEAD
  git -C "${GIT_WORKDIR}" checkout -q -b feature/needs-input
  git -C "${GIT_WORKDIR}" commit --allow-empty -m "agent work" -q
}

run_post_code_in_git_workdir() {
  local fixture_json="$1"
  local fixture_dir="${TMPDIR}/fixture-input"
  rm -rf "${fixture_dir}"
  mkdir -p "${fixture_dir}"
  echo "${fixture_json}" > "${fixture_dir}/agent-result.json"

  : > "${GH_LOG}"

  EXIT_CODE=0
  (
    cd "${GIT_WORKDIR}" && \
    PATH="${MOCK_BIN}:${PATH}" \
    REPO_DIR="." \
    PUSH_TOKEN="fake-token" \
    REPO_FULL_NAME="${REPO_FULL_NAME}" \
    ISSUE_NUMBER="${ISSUE_NUMBER}" \
    FULLSEND_FORGE="github" \
    FULLSEND_VALIDATED_ITERATION_DIR="${fixture_dir}" \
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || EXIT_CODE=$?
}

setup_git_workdir_with_commits_ahead
run_post_code_in_git_workdir "${FIXTURE_NEEDS_INPUT}"

assert_log_pattern "needs-input-warns-on-discarded-commits" \
  "were not pushed and will be discarded" "yes"

assert_log_pattern "needs-input-conflict-label-applied-on-discarded-commits" \
  "labels[]=fs-code-needs-input-conflict" "yes"

assert_exit_code "needs-input-with-commits-still-exits-zero" 0

# Same git state, but gh pr list reports an already-open PR for the branch —
# the "existing PR" caveat should win over the "discarded commits" one.
MOCK_EXISTING_PR_URL="https://github.com/${REPO_FULL_NAME}/pull/7" \
  run_post_code_in_git_workdir "${FIXTURE_NEEDS_INPUT}"

assert_log_pattern "needs-input-warns-on-existing-pr" \
  "An open PR already exists for branch" "yes"

assert_log_pattern "needs-input-conflict-label-applied-on-existing-pr" \
  "labels[]=fs-code-needs-input-conflict" "yes"

assert_log_pattern "needs-input-existing-pr-caveat-omits-discarded-commits" \
  "were not pushed and will be discarded" "no"

# PR URLs from gh pr list should be validated before interpolation into the
# comment body (defense-in-depth against injection via forged API responses).
# A URL containing unexpected characters must be replaced with a placeholder.
MOCK_EXISTING_PR_URL='https://github.com/owner/repo/pull/7?x=`whoami`' \
  run_post_code_in_git_workdir "${FIXTURE_NEEDS_INPUT}"

assert_comment_body_pattern "needs-input-bad-pr-url-omitted-from-comment" \
  '`whoami`' "no"

assert_comment_body_pattern "needs-input-bad-pr-url-placeholder-used" \
  "PR URL omitted" "yes"

# A valid PR URL must pass through normally.
MOCK_EXISTING_PR_URL="https://github.com/${REPO_FULL_NAME}/pull/7" \
  run_post_code_in_git_workdir "${FIXTURE_NEEDS_INPUT}"

assert_comment_body_pattern "needs-input-valid-pr-url-included" \
  "https://github.com/${REPO_FULL_NAME}/pull/7" "yes"

# Branch names are chosen by the code agent and git ref names permit
# backticks — a branch name containing one must never be interpolated raw
# into the posted comment body, since it would break out of the markdown
# code span it's wrapped in.
BACKTICK_BRANCH='feature/`whoami`-needs-input'

setup_git_workdir_with_backtick_branch() {
  rm -rf "${GIT_WORKDIR}"
  git init -q -b main "${GIT_WORKDIR}"
  git -C "${GIT_WORKDIR}" config user.email "test@example.com"
  git -C "${GIT_WORKDIR}" config user.name "Test"
  git -C "${GIT_WORKDIR}" commit --allow-empty -m "init" -q
  git -C "${GIT_WORKDIR}" update-ref refs/remotes/origin/main HEAD
  git -C "${GIT_WORKDIR}" checkout -q -b "${BACKTICK_BRANCH}"
  git -C "${GIT_WORKDIR}" commit --allow-empty -m "agent work" -q
}

setup_git_workdir_with_backtick_branch
MOCK_EXISTING_PR_URL="" run_post_code_in_git_workdir "${FIXTURE_NEEDS_INPUT}"

assert_comment_body_pattern "needs-input-backtick-branch-omitted-from-comment" \
  "${BACKTICK_BRANCH}" "no"

assert_comment_body_pattern "needs-input-backtick-branch-placeholder-used" \
  "branch name omitted" "yes"

# --- Default-branch commits check ---
# The commits_ahead guard must fire even when the agent is on the default
# branch (e.g. the agent never created a feature branch). Previously the
# check was gated on current_branch != default_branch, which silently
# skipped it in that scenario.
setup_git_workdir_on_default_branch() {
  rm -rf "${GIT_WORKDIR}"
  git init -q -b main "${GIT_WORKDIR}"
  git -C "${GIT_WORKDIR}" config user.email "test@example.com"
  git -C "${GIT_WORKDIR}" config user.name "Test"
  git -C "${GIT_WORKDIR}" commit --allow-empty -m "init" -q
  git -C "${GIT_WORKDIR}" update-ref refs/remotes/origin/main HEAD
  # Stay on main, add a commit ahead of origin/main
  git -C "${GIT_WORKDIR}" commit --allow-empty -m "agent work on main" -q
}

setup_git_workdir_on_default_branch
run_post_code_in_git_workdir "${FIXTURE_NEEDS_INPUT}"

assert_log_pattern "needs-input-warns-on-commits-ahead-on-default-branch" \
  "were not pushed and will be discarded" "yes"

assert_log_pattern "needs-input-conflict-label-on-default-branch-commits" \
  "labels[]=fs-code-needs-input-conflict" "yes"

# --- Uncommitted files check ---
# The agent may modify files without committing. The guard should surface
# uncommitted working-tree changes via a git status --porcelain check.
setup_git_workdir_with_dirty_files() {
  rm -rf "${GIT_WORKDIR}"
  git init -q -b main "${GIT_WORKDIR}"
  git -C "${GIT_WORKDIR}" config user.email "test@example.com"
  git -C "${GIT_WORKDIR}" config user.name "Test"
  git -C "${GIT_WORKDIR}" commit --allow-empty -m "init" -q
  git -C "${GIT_WORKDIR}" update-ref refs/remotes/origin/main HEAD
  git -C "${GIT_WORKDIR}" checkout -q -b feature/dirty-needs-input
  # Create an uncommitted file
  echo "uncommitted agent work" > "${GIT_WORKDIR}/agent-changes.txt"
}

setup_git_workdir_with_dirty_files
run_post_code_in_git_workdir "${FIXTURE_NEEDS_INPUT}"

assert_log_pattern "needs-input-warns-on-uncommitted-files" \
  "uncommitted file(s) in the working tree" "yes"

assert_log_pattern "needs-input-conflict-label-on-uncommitted-files" \
  "labels[]=fs-code-needs-input-conflict" "yes"

# --- Label validation ---
# CODE_NEEDS_INPUT_LABEL with unexpected characters must fall back to default.
run_post_code_with_label "${FIXTURE_NEEDS_INPUT}" 'bad-label`inject`'

assert_log_pattern "needs-input-bad-label-falls-back-to-default" \
  "labels[]=fs-code-needs-input" "yes"

# --- Summary ---

echo ""
if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
