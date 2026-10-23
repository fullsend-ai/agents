#!/usr/bin/env bash
# pre-code-test.sh — Test pre-code.sh with mock gh to verify existing-PR check,
# tracking-issue (sub-issues) skip, and the pre-script output protocol skip
# signal (fullsend docs/normative/prescript-output/v1, fullsend-ai/fullsend#4718).
#
# Uses a mock gh command to capture calls without hitting GitHub.
# Run from the repo root: bash scripts/pre-code-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

PRE_SCRIPT="$(resolve_agent_script pre-code "${SCRIPT_DIR}")"
FAILURES=0

# Create a temp directory for mock state.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# --- Helpers ---

# build_mock creates a mock gh binary that returns preconfigured responses.
# Arguments:
#   $1 — JSON string to return for "gh api graphql" calls. When the caller
#        passes --jq, the mock pipes this JSON through jq so the real
#        filter expression is exercised.  Pass an empty string for no PRs.
#        Real `gh api` has no `--arg` flag, so the mock rejects it too.
build_mock() {
  local graphql_output="$1"
  local mock_bin="${TMPDIR}/bin"
  local gh_log="${TMPDIR}/gh-calls.log"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"
  : > "${gh_log}"

  # Write the GraphQL output to a file so the mock can read it.
  printf '%s' "${graphql_output}" > "${TMPDIR}/graphql-output.txt"

  cat > "${mock_bin}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
CALL_LOG="LOGFILE_PLACEHOLDER"
PR_OUTPUT="OUTPUT_PLACEHOLDER"

echo "gh $*" >> "${CALL_LOG}"

# Route by subcommand
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  # Parse --jq from arguments, just like the real gh CLI. Real `gh api`
  # has no --arg flag, so reject it here too.
  JQ_EXPR=""
  shift 2
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--jq" ]]; then
      JQ_EXPR="$2"
      shift 2
    elif [[ "$1" == "--arg" ]]; then
      echo "gh: unknown flag: --arg" >&2
      exit 1
    else
      shift
    fi
  done
  if [[ -n "${JQ_EXPR}" ]] && [[ -s "${PR_OUTPUT}" ]]; then
    jq -r "${JQ_EXPR}" "${PR_OUTPUT}"
  else
    cat "${PR_OUTPUT}"
  fi
elif [[ "$1" == "label" ]]; then
  exit 0
elif [[ "$1" == "api" ]]; then
  exit 0
elif [[ "$1" == "issue" && "$2" == "comment" ]]; then
  # Consume stdin (body-file reads from stdin)
  cat > /dev/null
  exit 0
fi
MOCKEOF

  # Patch placeholders with actual paths (avoid sed on source files,
  # but this is a generated mock — not repo source code).
  local escaped_log="${gh_log//\//\\/}"
  local escaped_out="${TMPDIR//\//\\/}\/graphql-output.txt"
  perl -pi -e "s/LOGFILE_PLACEHOLDER/${escaped_log}/g" "${mock_bin}/gh"
  perl -pi -e "s/OUTPUT_PLACEHOLDER/${escaped_out}/g" "${mock_bin}/gh"

  chmod +x "${mock_bin}/gh"

  echo "${mock_bin}"
}

run_test() {
  local test_name="$1"
  local graphql_output="$2"
  local expected_pattern="$3"
  local expect_exit="$4"         # 0 = success, 1 = failure
  local extra_env="${5:-}"       # additional env vars (KEY=VAL KEY2=VAL2)

  local mock_bin
  mock_bin="$(build_mock "${graphql_output}")"
  local gh_log="${TMPDIR}/gh-calls.log"
  local gh_output="${TMPDIR}/github-output.txt"
  : > "${gh_output}"

  # Set base env vars for the script.
  local env_cmd=(
    env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY
    PATH="${mock_bin}:${PATH}"
    ISSUE_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    FULLSEND_FORGE="github"
    GH_TOKEN="fake-token"
    GITHUB_OUTPUT="${gh_output}"
  )

  # Add extra env vars if provided (read line-by-line to support values with spaces).
  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  # Check exit code.
  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # The script must never write to GITHUB_OUTPUT — the legacy skipped= writes
  # were removed in favor of the pre-script output protocol, and fullsend run's
  # own relay writes to this file (last-write-wins collision otherwise).
  if [[ -s "${gh_output}" ]]; then
    echo "FAIL: ${test_name} — unexpected GITHUB_OUTPUT writes:"
    cat "${gh_output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # Check expected pattern in gh calls (if provided).
  if [[ -n "${expected_pattern}" ]]; then
    if ! grep -qF "${expected_pattern}" "${gh_log}" 2>/dev/null; then
      echo "FAIL: ${test_name} — expected gh call pattern '${expected_pattern}' not found"
      echo "Actual calls:"
      cat "${gh_log}" 2>/dev/null || echo "(no calls)"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# Check stdout contains a specific string.
run_test_stdout() {
  local test_name="$1"
  local graphql_output="$2"
  local expected_stdout="$3"
  local expect_exit="$4"
  local extra_env="${5:-}"

  local mock_bin
  mock_bin="$(build_mock "${graphql_output}")"
  local gh_output="${TMPDIR}/github-output.txt"
  : > "${gh_output}"

  local env_cmd=(
    env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY
    PATH="${mock_bin}:${PATH}"
    ISSUE_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    FULLSEND_FORGE="github"
    GH_TOKEN="fake-token"
    GITHUB_OUTPUT="${gh_output}"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # The script must never write to GITHUB_OUTPUT — the legacy skipped= writes
  # were removed in favor of the pre-script output protocol, and fullsend run's
  # own relay writes to this file (last-write-wins collision otherwise).
  if [[ -s "${gh_output}" ]]; then
    echo "FAIL: ${test_name} — unexpected GITHUB_OUTPUT writes:"
    cat "${gh_output}"
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

# Check stdout contains one string and does NOT contain another.
run_test_stdout_excludes() {
  local test_name="$1"
  local graphql_output="$2"
  local expected_stdout="$3"
  local excluded_stdout="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_mock "${graphql_output}")"
  local gh_output="${TMPDIR}/github-output.txt"
  : > "${gh_output}"

  local env_cmd=(
    env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY
    PATH="${mock_bin}:${PATH}"
    ISSUE_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    FULLSEND_FORGE="github"
    GH_TOKEN="fake-token"
    GITHUB_OUTPUT="${gh_output}"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # The script must never write to GITHUB_OUTPUT — the legacy skipped= writes
  # were removed in favor of the pre-script output protocol, and fullsend run's
  # own relay writes to this file (last-write-wins collision otherwise).
  if [[ -s "${gh_output}" ]]; then
    echo "FAIL: ${test_name} — unexpected GITHUB_OUTPUT writes:"
    cat "${gh_output}"
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

  if grep -qF "${excluded_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — excluded stdout '${excluded_stdout}' was found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Test cases ---

# JSON helpers — build GraphQL response JSON that the mock returns to the
# script. The response format matches GitHub's closedByPullRequestsReferences
# query; pre-code.sh pipes it through its own `jq -r --arg ...` filter.

_gql_wrap() {
  # Wrap a JSON array of PR nodes into a closedByPullRequestsReferences response.
  local nodes="$1"
  printf '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":%s}}}}}' "${nodes}"
}

# Combined response so both GraphQL queries (PRs and sub-issues) can share
# one mock payload. Missing subIssues is treated as totalCount 0 by the jq
# filter; this helper sets an explicit count when tests need it.
_gql_wrap_sub() {
  local nodes="$1"
  local sub_count="$2"
  printf '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":%s},"subIssues":{"totalCount":%s}}}}}' "${nodes}" "${sub_count}"
}

# Empty response (no closing PRs).
EMPTY_GQL_JSON="$(_gql_wrap '[]')"

# Single human PR. GraphQL always includes __typename on the author.
HUMAN_PR_JSON="$(_gql_wrap '[{"number":99,"url":"https://github.com/test-org/test-repo/pull/99","author":{"login":"human-dev","__typename":"User"},"state":"OPEN"}]')"

# Single fullsend-ai bot PR, bare GraphQL-style login (no "[bot]" suffix).
BOT_PR_JSON="$(_gql_wrap '[{"number":10,"url":"https://github.com/test-org/test-repo/pull/10","author":{"login":"fullsend-ai","__typename":"Bot"},"state":"OPEN"}]')"

# Single fullsend-ai-coder bot PR, bare GraphQL-style login.
CODER_BOT_PR_JSON="$(_gql_wrap '[{"number":11,"url":"https://github.com/test-org/test-repo/pull/11","author":{"login":"fullsend-ai-coder","__typename":"Bot"},"state":"OPEN"}]')"

# Single custom-app[bot] PR (custom FULLSEND_APP_SET, no role suffix), bare
# GraphQL-style login.
CUSTOM_BOT_PR_JSON="$(_gql_wrap '[{"number":12,"url":"https://github.com/test-org/test-repo/pull/12","author":{"login":"custom-app","__typename":"Bot"},"state":"OPEN"}]')"

# Single custom-app-coder[bot] PR (custom FULLSEND_APP_SET coder identity),
# bare GraphQL-style login.
CUSTOM_CODER_BOT_PR_JSON="$(_gql_wrap '[{"number":13,"url":"https://github.com/test-org/test-repo/pull/13","author":{"login":"custom-app-coder","__typename":"Bot"},"state":"OPEN"}]')"

# Both bot PRs plus a human PR.
MIXED_PR_JSON="$(_gql_wrap '[{"number":10,"url":"https://github.com/test-org/test-repo/pull/10","author":{"login":"fullsend-ai","__typename":"Bot"},"state":"OPEN"},{"number":11,"url":"https://github.com/test-org/test-repo/pull/11","author":{"login":"fullsend-ai-coder","__typename":"Bot"},"state":"OPEN"},{"number":99,"url":"https://github.com/test-org/test-repo/pull/99","author":{"login":"human-dev","__typename":"User"},"state":"OPEN"}]')"

# Multiple human PRs.
MULTI_HUMAN_PR_JSON="$(_gql_wrap '[{"number":50,"url":"https://github.com/test-org/test-repo/pull/50","author":{"login":"dev-a","__typename":"User"},"state":"OPEN"},{"number":51,"url":"https://github.com/test-org/test-repo/pull/51","author":{"login":"dev-b","__typename":"User"},"state":"OPEN"}]')"

# Both bots only (no human PRs).
BOTH_BOTS_JSON="$(_gql_wrap '[{"number":10,"url":"https://github.com/test-org/test-repo/pull/10","author":{"login":"fullsend-ai","__typename":"Bot"},"state":"OPEN"},{"number":11,"url":"https://github.com/test-org/test-repo/pull/11","author":{"login":"fullsend-ai-coder","__typename":"Bot"},"state":"OPEN"}]')"

# Human PR in MERGED state (should be filtered out by .state == "OPEN").
MERGED_PR_JSON="$(_gql_wrap '[{"number":99,"url":"https://github.com/test-org/test-repo/pull/99","author":{"login":"human-dev","__typename":"User"},"state":"MERGED"}]')"

# Human PR in CLOSED state (should be filtered out by .state == "OPEN").
CLOSED_PR_JSON="$(_gql_wrap '[{"number":99,"url":"https://github.com/test-org/test-repo/pull/99","author":{"login":"human-dev","__typename":"User"},"state":"CLOSED"}]')"

# No existing PRs → agent proceeds (exit 0, no label/comment).
run_test_stdout "no-existing-prs-proceeds" \
  "${EMPTY_GQL_JSON}" \
  "No existing human PRs found" \
  0

# Human PR exists → should apply label and comment, then exit 0.
run_test "human-pr-applies-label" \
  "${HUMAN_PR_JSON}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=pr-open --silent" \
  0

run_test "human-pr-posts-comment" \
  "${HUMAN_PR_JSON}" \
  "gh issue comment 42 --repo test-org/test-repo --body-file -" \
  0

run_test_stdout "human-pr-skips-agent" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0

# Bot PR only → jq filter removes it → script sees empty output → proceeds.
run_test_stdout "bot-pr-does-not-block" \
  "${BOT_PR_JSON}" \
  "No existing human PRs found" \
  0

# CODE_FORCE=true → should skip check even with human PR.
run_test_stdout "force-override-code-force" \
  "${HUMAN_PR_JSON}" \
  "Force override" \
  0 \
  "CODE_FORCE=true"

# COMMENT_BODY contains --force → should also skip check.
run_test_stdout "force-override-comment-body" \
  "${HUMAN_PR_JSON}" \
  "Force override" \
  0 \
  "COMMENT_BODY=/fs-code --force"

# No GH_TOKEN → skips check entirely, exits 0.
run_test_stdout "no-gh-token-skips-check" \
  "${EMPTY_GQL_JSON}" \
  "No github token set" \
  0 \
  "GH_TOKEN="

# Coder bot PR only → jq filter removes it → script proceeds.
run_test_stdout "coder-bot-pr-does-not-block" \
  "${CODER_BOT_PR_JSON}" \
  "No existing human PRs found" \
  0

# Both bots + human PR → jq filter removes bots, human PR blocks.
run_test_stdout "coder-bot-pr-plus-human-pr-blocks" \
  "${MIXED_PR_JSON}" \
  "Skipping code agent" \
  0

# Both bots only → jq filter removes all → script proceeds.
run_test_stdout "both-bots-do-not-block" \
  "${BOTH_BOTS_JSON}" \
  "No existing human PRs found" \
  0

# --- Regression tests: FULLSEND_APP_SET custom bot identities (issue #1584) ---

# Custom coder bot PR + matching FULLSEND_APP_SET → recognized as bot, proceeds.
run_test_stdout "custom-app-set-coder-bot-pr-does-not-block" \
  "${CUSTOM_CODER_BOT_PR_JSON}" \
  "No existing human PRs found" \
  0 \
  "FULLSEND_APP_SET=custom-app"

# Custom (non-coder) bot PR + matching FULLSEND_APP_SET → recognized as bot, proceeds.
run_test_stdout "custom-app-set-bot-pr-does-not-block" \
  "${CUSTOM_BOT_PR_JSON}" \
  "No existing human PRs found" \
  0 \
  "FULLSEND_APP_SET=custom-app"

# Same PR author, but FULLSEND_APP_SET unset → derived default logins don't
# match "custom-app-coder[bot]", so it's treated as a human PR and blocks.
run_test_stdout "custom-coder-login-blocks-without-app-set" \
  "${CUSTOM_CODER_BOT_PR_JSON}" \
  "Skipping code agent" \
  0

# Multiple human PRs → should block and apply label.
run_test "multiple-human-prs-block" \
  "${MULTI_HUMAN_PR_JSON}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=pr-open --silent" \
  0

run_test_stdout "multiple-human-prs-notice" \
  "${MULTI_HUMAN_PR_JSON}" \
  "Found existing human PR #50 by @dev-a" \
  0

# PR label gets created.
run_test "pr-label-created" \
  "${HUMAN_PR_JSON}" \
  "gh label create pr-open --repo test-org/test-repo" \
  0

# --- Regression tests: --force bypasses PR search (issue #1697) ---

# COMMENT_BODY with --force must exit before PR search is reached.
run_test_stdout_excludes "force-comment-body-no-pr-search" \
  "${HUMAN_PR_JSON}" \
  "Force override" \
  "Checking for existing open PRs" \
  0 \
  "COMMENT_BODY=/fs-code --force"

# CODE_FORCE=true must exit before PR search is reached.
run_test_stdout_excludes "force-code-force-no-pr-search" \
  "${HUMAN_PR_JSON}" \
  "Force override" \
  "Checking for existing open PRs" \
  0 \
  "CODE_FORCE=true"

# Force check logs COMMENT_BODY value for debuggability.
run_test_stdout "force-check-logs-comment-body" \
  "${EMPTY_GQL_JSON}" \
  "Evaluating force override:" \
  0 \
  "COMMENT_BODY=/fs-code --force"

# Without --force, PR search IS reached (no false bypass).
run_test_stdout "no-force-reaches-pr-search" \
  "${EMPTY_GQL_JSON}" \
  "Checking for existing open PRs" \
  0 \
  "COMMENT_BODY=/fs-code"

# --- Regression: multiline COMMENT_BODY cannot inject a workflow command ---
# A comment whose second line starts with "::error::" must not reach
# stdout as its own line via the force-override log.
test_name="force-check-sanitizes-multiline-comment-body"
mock_bin="$(build_mock "${EMPTY_GQL_JSON}")"
injection_output="${TMPDIR}/github-output-injection.txt"
: > "${injection_output}"
injection_stdout="${TMPDIR}/stdout-injection.log"
injection_exit=0
env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE \
  PATH="${mock_bin}:${PATH}" \
  ISSUE_NUMBER="42" \
  REPO_FULL_NAME="test-org/test-repo" \
  GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42" \
  ISSUE_URL="https://github.com/test-org/test-repo/issues/42" \
  FULLSEND_FORGE="github" \
  GH_TOKEN="fake-token" \
  GITHUB_OUTPUT="${injection_output}" \
  COMMENT_BODY=$'/fs-code --force\n::error::injected-workflow-command' \
  bash "${PRE_SCRIPT}" > "${injection_stdout}" 2>&1 || injection_exit=$?

if [[ ${injection_exit} -ne 0 ]]; then
  echo "FAIL: ${test_name} — expected exit 0, got ${injection_exit}"
  cat "${injection_stdout}"
  FAILURES=$((FAILURES + 1))
elif grep -qE '^::error::injected-workflow-command' "${injection_stdout}"; then
  echo "FAIL: ${test_name} — injected workflow command appeared at start of a stdout line"
  cat "${injection_stdout}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: ${test_name}"
fi

# --- Regression: OSC sequences and other control characters must not
# survive sanitization into logged output ---
# The sanitizer previously only stripped CSI escapes; OSC sequences and
# raw control bytes like backspace survived into runner logs.
test_name="force-check-strips-osc-and-control-chars-from-comment-body"
mock_bin="$(build_mock "${EMPTY_GQL_JSON}")"
control_output="${TMPDIR}/github-output-control.txt"
: > "${control_output}"
control_stdout="${TMPDIR}/stdout-control.log"
control_exit=0
env -u FULLSEND_PRESCRIPT_OUTPUT \
  PATH="${mock_bin}:${PATH}" \
  ISSUE_NUMBER="42" \
  REPO_FULL_NAME="test-org/test-repo" \
  GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42" \
  ISSUE_URL="https://github.com/test-org/test-repo/issues/42" \
  FULLSEND_FORGE="github" \
  GH_TOKEN="fake-token" \
  GITHUB_OUTPUT="${control_output}" \
  CODE_FORCE="true" \
  COMMENT_BODY=$'line-one\n\x1b]0;evil-title\x07\x08trailing' \
  bash "${PRE_SCRIPT}" > "${control_stdout}" 2>&1 || control_exit=$?

if [[ ${control_exit} -ne 0 ]]; then
  echo "FAIL: ${test_name} — expected exit 0, got ${control_exit}"
  cat "${control_stdout}"
  FAILURES=$((FAILURES + 1))
elif grep -q $'\x1b' "${control_stdout}" || grep -q $'\x08' "${control_stdout}"; then
  echo "FAIL: ${test_name} — raw ESC/control byte survived sanitization"
  cat "${control_stdout}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: ${test_name}"
fi

# --- Regression: horizontal tabs must not survive sanitization ---
# The control-character deletion range previously skipped \011 (tab),
# letting a tab in CODE_FORCE or COMMENT_BODY reach the logs.
test_name="force-check-strips-tabs-from-code-force-and-comment-body"
mock_bin="$(build_mock "${EMPTY_GQL_JSON}")"
tab_output="${TMPDIR}/github-output-tab.txt"
: > "${tab_output}"
tab_stdout="${TMPDIR}/stdout-tab.log"
tab_exit=0
env -u FULLSEND_PRESCRIPT_OUTPUT \
  PATH="${mock_bin}:${PATH}" \
  ISSUE_NUMBER="42" \
  REPO_FULL_NAME="test-org/test-repo" \
  GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42" \
  ISSUE_URL="https://github.com/test-org/test-repo/issues/42" \
  FULLSEND_FORGE="github" \
  GH_TOKEN="fake-token" \
  GITHUB_OUTPUT="${tab_output}" \
  CODE_FORCE=$'true\textra' \
  COMMENT_BODY=$'/fs-code\tstatus-update' \
  bash "${PRE_SCRIPT}" > "${tab_stdout}" 2>&1 || tab_exit=$?

if [[ ${tab_exit} -ne 0 ]]; then
  echo "FAIL: ${test_name} — expected exit 0, got ${tab_exit}"
  cat "${tab_stdout}"
  FAILURES=$((FAILURES + 1))
elif ! grep -qF "Evaluating force override:" "${tab_stdout}"; then
  echo "FAIL: ${test_name} — force override log line not found"
  cat "${tab_stdout}"
  FAILURES=$((FAILURES + 1))
elif grep -q $'\t' "${tab_stdout}"; then
  echo "FAIL: ${test_name} — raw tab survived sanitization"
  cat "${tab_stdout}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: ${test_name}"
fi

# --- Regression: the hardened sanitizer must apply on GitLab too,
# regardless of forge-library load order ---
# The GitLab path transitively loads an older, weaker _gha_sanitize; a
# `declare -F` guard would keep it and leak control chars into logs.
test_name="force-check-strips-osc-and-control-chars-from-comment-body-gitlab"
gitlab_output="${TMPDIR}/github-output-gitlab.txt"
: > "${gitlab_output}"
gitlab_stdout="${TMPDIR}/stdout-gitlab.log"
gitlab_exit=0
env -u FULLSEND_PRESCRIPT_OUTPUT -u GH_TOKEN -u GITLAB_TOKEN \
  PATH="${PATH}" \
  ISSUE_NUMBER="42" \
  REPO_FULL_NAME="test-org/test-repo" \
  ISSUE_URL="https://gitlab.example.com/test-org/test-repo/-/issues/42" \
  FULLSEND_FORGE="gitlab" \
  CI_SERVER_HOST="gitlab.example.com" \
  GITHUB_OUTPUT="${gitlab_output}" \
  CODE_FORCE="true" \
  COMMENT_BODY=$'line-one\n\x1b]0;evil-title\x07\x08trailing' \
  bash "${PRE_SCRIPT}" > "${gitlab_stdout}" 2>&1 || gitlab_exit=$?

if [[ ${gitlab_exit} -ne 0 ]]; then
  echo "FAIL: ${test_name} — expected exit 0, got ${gitlab_exit}"
  cat "${gitlab_stdout}"
  FAILURES=$((FAILURES + 1))
elif ! grep -qF "Evaluating force override:" "${gitlab_stdout}"; then
  echo "FAIL: ${test_name} — force override log line not found"
  cat "${gitlab_stdout}"
  FAILURES=$((FAILURES + 1))
elif grep -q $'\x1b' "${gitlab_stdout}" || grep -q $'\x08' "${gitlab_stdout}"; then
  echo "FAIL: ${test_name} — raw ESC/control byte survived sanitization on the GitLab path"
  cat "${gitlab_stdout}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: ${test_name}"
fi

# --- Regression: malformed ISSUE_URL must not inject a workflow command ---
# ISSUE_URL is echoed raw in several places before validation; a malformed
# value's second line must not reach stdout as its own workflow command.
test_name="malformed-issue-url-does-not-inject-workflow-command"
mock_bin="$(build_mock "${EMPTY_GQL_JSON}")"
badurl_output="${TMPDIR}/github-output-badurl.txt"
: > "${badurl_output}"
badurl_stdout="${TMPDIR}/stdout-badurl.log"
badurl_exit=0
MALFORMED_ISSUE_URL=$'https://github.com/test-org/test-repo/issues/42\n::add-mask::injected-workflow-command'
env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY \
  PATH="${mock_bin}:${PATH}" \
  ISSUE_NUMBER="42" \
  REPO_FULL_NAME="test-org/test-repo" \
  ISSUE_URL="${MALFORMED_ISSUE_URL}" \
  FULLSEND_FORGE="github" \
  GH_TOKEN="fake-token" \
  GITHUB_OUTPUT="${badurl_output}" \
  bash "${PRE_SCRIPT}" > "${badurl_stdout}" 2>&1 || badurl_exit=$?

if [[ ${badurl_exit} -ne 1 ]]; then
  echo "FAIL: ${test_name} — expected exit 1 (validation failure), got ${badurl_exit}"
  cat "${badurl_stdout}"
  FAILURES=$((FAILURES + 1))
elif grep -qE '^::add-mask::injected-workflow-command' "${badurl_stdout}"; then
  echo "FAIL: ${test_name} — injected workflow command appeared at start of a stdout line"
  cat "${badurl_stdout}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: ${test_name}"
fi

# --- Regression: missing-token bypass must not SIGPIPE on a long multiline
# COMMENT_BODY (found during review of #1583) ---
# Piping a large COMMENT_BODY through `head -1` could SIGPIPE the upstream
# `printf`, which `set -euo pipefail` turns into a script-ending error
# before runner setup runs.
test_name="no-token-long-multiline-comment-reaches-precommit-install-section"
mock_bin="$(build_mock "${EMPTY_GQL_JSON}")"
sigpipe_output="${TMPDIR}/github-output-sigpipe.txt"
: > "${sigpipe_output}"
sigpipe_stdout="${TMPDIR}/stdout-sigpipe.log"
sigpipe_exit=0
LONG_COMMENT_BODY="$(printf '/fs-code status update\n%s\n' "$(printf 'A%.0s' $(seq 1 100000))")"
env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u GH_TOKEN \
  PATH="${mock_bin}:${PATH}" \
  ISSUE_NUMBER="42" \
  REPO_FULL_NAME="test-org/test-repo" \
  GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42" \
  ISSUE_URL="https://github.com/test-org/test-repo/issues/42" \
  FULLSEND_FORGE="github" \
  GITHUB_OUTPUT="${sigpipe_output}" \
  REPO_DIR="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}" \
  GITHUB_WORKSPACE="" \
  COMMENT_BODY="${LONG_COMMENT_BODY}" \
  bash "${PRE_SCRIPT}" > "${sigpipe_stdout}" 2>&1 || sigpipe_exit=$?

if [[ ${sigpipe_exit} -ne 0 ]]; then
  echo "FAIL: ${test_name} — expected exit 0, got ${sigpipe_exit} (possible SIGPIPE regression)"
  tail -c 2000 "${sigpipe_stdout}"
  FAILURES=$((FAILURES + 1))
elif ! grep -qF "No github token set" "${sigpipe_stdout}"; then
  echo "FAIL: ${test_name} — did not take the missing-token bypass path"
  tail -c 2000 "${sigpipe_stdout}"
  FAILURES=$((FAILURES + 1))
elif ! grep -qF "Pre-commit tool auto-install skipped: companion scripts not found" "${sigpipe_stdout}"; then
  echo "FAIL: ${test_name} — did not reach pre-commit install section (PATH setup)"
  tail -c 2000 "${sigpipe_stdout}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: ${test_name}"
fi

# --- Anchoring: --force counts only as the command's flag token ---
# Mirrors the dispatch router's first-line tokenization. A comment that
# merely mentions --force must not bypass the existing-PR check.

# A longer flag sharing the prefix does not bypass; the check still blocks.
run_test_stdout "forceful-prefix-does-not-bypass" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0 \
  "COMMENT_BODY=/fs-code --forceful"

# A mid-sentence mention of --force does not bypass.
run_test_stdout "force-mid-sentence-does-not-bypass" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0 \
  "COMMENT_BODY=please don't use --force on this issue"

# --force anywhere but the flag position does not bypass.
run_test_stdout "force-third-token-does-not-bypass" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0 \
  "COMMENT_BODY=/fs-code now --force"

# --- Pre-script output protocol tests (fullsend-ai/fullsend#4718) ---
# Contract: fullsend docs/normative/prescript-output/v1. The script writes
# skipped=true (plus reason=...) to FULLSEND_PRESCRIPT_OUTPUT only when an
# open human PR blocks the run; every proceed path leaves the file empty
# (absent skipped means proceed).

# Helper: run pre-code.sh with FULLSEND_PRESCRIPT_OUTPUT set and assert the
# protocol file's exact content ("" = must stay empty).
run_test_prescript_output() {
  local test_name="$1"
  local graphql_output="$2"
  local expected_content="$3"
  local expect_exit="$4"
  local extra_env="${5:-}"

  local mock_bin
  mock_bin="$(build_mock "${graphql_output}")"
  local proto_out="${TMPDIR}/prescript-output.txt"
  local gh_output="${TMPDIR}/github-output.txt"
  : > "${proto_out}"
  : > "${gh_output}"

  local env_cmd=(
    env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY
    PATH="${mock_bin}:${PATH}"
    ISSUE_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    FULLSEND_FORGE="github"
    GH_TOKEN="fake-token"
    GITHUB_OUTPUT="${gh_output}"
    FULLSEND_PRESCRIPT_OUTPUT="${proto_out}"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # The script must never write to GITHUB_OUTPUT — the legacy skipped= writes
  # were removed in favor of the pre-script output protocol, and fullsend run's
  # own relay writes to this file (last-write-wins collision otherwise).
  if [[ -s "${gh_output}" ]]; then
    echo "FAIL: ${test_name} — unexpected GITHUB_OUTPUT writes:"
    cat "${gh_output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! diff <(printf '%s' "${expected_content}") "${proto_out}" > "${TMPDIR}/proto-diff.log" 2>&1; then
    echo "FAIL: ${test_name} — protocol output mismatch"
    cat "${TMPDIR}/proto-diff.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

NL=$'\n'

# Existing human PR → skipped=true with a single-line reason naming the PR.
run_test_prescript_output "protocol-skip-on-existing-pr" \
  "${HUMAN_PR_JSON}" \
  "skipped=true${NL}reason=open PR #99 by @human-dev already addresses issue #42${NL}" \
  0

# No existing PRs → file stays empty (absent skipped = proceed).
run_test_prescript_output "protocol-empty-on-no-prs" \
  "${EMPTY_GQL_JSON}" \
  "" \
  0

# Force override exits before the PR check → file stays empty.
run_test_prescript_output "protocol-empty-on-force" \
  "${HUMAN_PR_JSON}" \
  "" \
  0 \
  "CODE_FORCE=true"

# No GH_TOKEN → check skipped, run proceeds → file stays empty.
run_test_prescript_output "protocol-empty-on-no-token" \
  "${EMPTY_GQL_JSON}" \
  "" \
  0 \
  "GH_TOKEN="

# Bot-only PRs are filtered out → proceed → file stays empty.
run_test_prescript_output "protocol-empty-on-bot-prs" \
  "${BOT_PR_JSON}" \
  "" \
  0

# Old-CLI guard (fails open by design, see the protocol's Version skew
# section): FULLSEND_PRESCRIPT_OUTPUT unset + existing human PR → the
# script must not crash under set -u; it comments/labels and exits 0.
# All earlier tests in this file also run with the variable unset; this
# one documents the skip path explicitly.
run_test_stdout "protocol-unset-env-old-cli-fails-open" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0

# --- Regression tests: false-positive PR matching (issue #847) ---
# The old text-search approach (gh pr list --search "N in:body,title") caused
# false positives.  The new GraphQL closedByPullRequestsReferences query
# returns only PRs with closing keywords (Fixes, Closes, etc.), eliminating
# these scenarios at the API level.  The mock returns an empty response
# because the API would not match these PRs.

# Issue #1 must NOT be blocked by a PR titled "docs(#12): add fullsend-
# managed file exemption" that has no closing reference to issue #1.
# Old text search matched because "1" appears as a substring of "#12".
run_test_stdout "fp-issue847-title-substring-no-closing-ref" \
  "${EMPTY_GQL_JSON}" \
  "No existing human PRs found" \
  0 \
  "ISSUE_NUMBER=1
GITHUB_ISSUE_URL=https://github.com/test-org/test-repo/issues/1
ISSUE_URL=https://github.com/test-org/test-repo/issues/1"

# Issue #42 must NOT be blocked by a PR whose body contains "Related: #42"
# without a closing keyword.  The old text search matched on the bare "#42"
# mention; closedByPullRequestsReferences ignores non-closing references.
run_test_stdout "fp-issue847-related-without-closing-keyword" \
  "${EMPTY_GQL_JSON}" \
  "No existing human PRs found" \
  0

# Issue #1 must NOT be blocked by a PR whose body contains "#10" — a
# different issue number that merely shares a digit prefix.  The old text
# search for "1" matched "#10" as a substring.
run_test_stdout "fp-issue847-different-issue-substring" \
  "${EMPTY_GQL_JSON}" \
  "No existing human PRs found" \
  0 \
  "ISSUE_NUMBER=1
GITHUB_ISSUE_URL=https://github.com/test-org/test-repo/issues/1
ISSUE_URL=https://github.com/test-org/test-repo/issues/1"

# --- Closed/merged PR filtering ---
# closedByPullRequestsReferences may return PRs in any state (OPEN, MERGED,
# CLOSED).  The jq filter selects only .state == "OPEN"; non-open PRs must
# not block.

# MERGED human PR → filtered out → script proceeds.
run_test_stdout "merged-pr-does-not-block" \
  "${MERGED_PR_JSON}" \
  "No existing human PRs found" \
  0

# CLOSED human PR → filtered out → script proceeds.
run_test_stdout "closed-pr-does-not-block" \
  "${CLOSED_PR_JSON}" \
  "No existing human PRs found" \
  0

# --- Positive closing-keyword match (happy-path) ---
# A PR returned by closedByPullRequestsReferences with state OPEN and a
# human author must still block.  This confirms the happy path works end-
# to-end with the new GraphQL response format (e.g. a PR whose body
# contains "Fixes #42" or "Closes #42").
run_test_stdout "closing-ref-open-pr-still-blocks" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0

# --- Tracking-issue skip (GitHub sub-issues, issue #1493) ---
# Parent/tracking issues with child work items must not dispatch the coder.
# The mock returns the same JSON to both GraphQL queries; _gql_wrap_sub
# includes subIssues.totalCount so the second query sees children.

SUB_ISSUES_GQL_JSON="$(_gql_wrap_sub '[]' 2)"
ZERO_SUB_ISSUES_GQL_JSON="$(_gql_wrap_sub '[]' 0)"
SUB_ISSUES_AND_HUMAN_PR_JSON="$(_gql_wrap_sub '[{"number":99,"url":"https://github.com/test-org/test-repo/pull/99","author":{"login":"human-dev","__typename":"User"},"state":"OPEN"}]' 2)"

# Sub-issues present, no human PRs → skip the code agent.
run_test_stdout "sub-issues-skip-agent" \
  "${SUB_ISSUES_GQL_JSON}" \
  "Skipping code agent — issue #42 is a tracking issue with sub-issue(s)" \
  0

run_test "sub-issues-posts-comment" \
  "${SUB_ISSUES_GQL_JSON}" \
  "gh issue comment 42 --repo test-org/test-repo --body-file -" \
  0

run_test_stdout "sub-issues-notice" \
  "${SUB_ISSUES_GQL_JSON}" \
  "has sub-issue(s)" \
  0

# Explicit totalCount 0 is a leaf issue → proceed.
run_test_stdout "zero-sub-issues-proceeds" \
  "${ZERO_SUB_ISSUES_GQL_JSON}" \
  "No sub-issues found" \
  0

# Missing subIssues field (existing PR-only payload) also proceeds.
run_test_stdout "missing-sub-issues-field-proceeds" \
  "${EMPTY_GQL_JSON}" \
  "No sub-issues found" \
  0

# Human PR takes precedence: both present → skip with the existing-PR message.
run_test_stdout "human-pr-precedes-sub-issues" \
  "${SUB_ISSUES_AND_HUMAN_PR_JSON}" \
  "Found existing human PR #99 by @human-dev" \
  0

run_test_stdout_excludes "human-pr-precedes-sub-issues-no-tracking-skip" \
  "${SUB_ISSUES_AND_HUMAN_PR_JSON}" \
  "Skipping code agent" \
  "tracking issue" \
  0

# --force bypasses the tracking-issue check (exits before it).
run_test_stdout_excludes "force-skips-sub-issues-check" \
  "${SUB_ISSUES_GQL_JSON}" \
  "Force override" \
  "Checking for sub-issues" \
  0 \
  "CODE_FORCE=true"

run_test_stdout_excludes "force-comment-skips-sub-issues-check" \
  "${SUB_ISSUES_GQL_JSON}" \
  "Force override" \
  "Checking for sub-issues" \
  0 \
  "COMMENT_BODY=/fs-code --force"

# Protocol: sub-issues skip writes skipped=true with a reason.
run_test_prescript_output "protocol-skip-on-sub-issues" \
  "${SUB_ISSUES_GQL_JSON}" \
  "skipped=true${NL}reason=issue #42 has sub-issue(s); implement the child issues instead${NL}" \
  0

# --- Regression: force/no-token bypass must still reach runner setup
# (issue #1583) ---
# The force-override and missing-token guards previously used a bare
# `exit 0`, which also skipped pre-commit tool resolution/install.
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

run_test_stdout "force-code-force-reaches-precommit-install-section" \
  "${EMPTY_GQL_JSON}" \
  "Pre-commit tool auto-install skipped: companion scripts not found" \
  0 \
  "CODE_FORCE=true
REPO_DIR=${REPO_ROOT}
GITHUB_WORKSPACE="

run_test_stdout "no-gh-token-reaches-precommit-install-section" \
  "${EMPTY_GQL_JSON}" \
  "Pre-commit tool auto-install skipped: companion scripts not found" \
  0 \
  "GH_TOKEN=
REPO_DIR=${REPO_ROOT}
GITHUB_WORKSPACE="

# Protocol: explicit zero sub-issues → proceed, file stays empty.
run_test_prescript_output "protocol-empty-on-zero-sub-issues" \
  "${ZERO_SUB_ISSUES_GQL_JSON}" \
  "" \
  0

# --- GitLab forge_list_prs_for_issue — fail open on API error (issue #1585) ---
# Exercises gitlab-code-ops.lib.sh directly, mocking the low-level API call.

run_gl_list_prs_test() {
  local test_name="$1"
  local mock_body="$2"
  local expect_exit="$3"
  local expect_output="$4"

  local gl_stderr_log="${TMPDIR}/gl-list-prs-stderr.log"
  local gl_output
  local gl_exit=0
  gl_output=$(
    unset GITLAB_CODE_OPS_SH_LOADED
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/gitlab-code-ops.lib.sh"

    # Override _gitlab_code_api with the test mock (AFTER source).
    eval "${mock_body}"

    export REPO_ENCODED="test-group%2Ftest-project"
    forge_list_prs_for_issue "42" "bot-login" "coder-bot-login" 2>"${gl_stderr_log}"
  ) || gl_exit=$?

  if [[ ${gl_exit} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${gl_exit}"
    cat "${gl_stderr_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ "${gl_output}" != "${expect_output}" ]]; then
    echo "FAIL: ${test_name} — expected output '${expect_output}', got '${gl_output}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# API failure on page 1 must fail open: exit 0, no PRs reported.
run_gl_list_prs_test "gitlab-list-prs-api-failure-fails-open" '
_gitlab_code_api() { return 1; }
' 0 ""

# Confirmed zero MRs (API succeeds, empty page) — same output, success path.
run_gl_list_prs_test "gitlab-list-prs-zero-mrs-confirmed" '
_gitlab_code_api() { echo "[]"; }
' 0 ""

# --- GitLab forge_list_prs_for_issue — production pre-script regression (#1585) ---
# End-to-end run of pre-code.sh with FULLSEND_FORGE=gitlab and every curl
# call failing; asserts the output file stays empty (run proceeds).

build_gitlab_api_failure_mock() {
  local mock_bin="${TMPDIR}/gl-bin"
  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"
  cat > "${mock_bin}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
  chmod +x "${mock_bin}/curl"
  echo "${mock_bin}"
}

run_gitlab_prescript_output_test() {
  local test_name="$1"
  local expected_content="$2"
  local expect_exit="$3"

  local mock_bin
  mock_bin="$(build_gitlab_api_failure_mock)"
  local proto_out="${TMPDIR}/gl-prescript-output.txt"
  : > "${proto_out}"

  local env_cmd=(
    env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY -u REPO_DIR -u CI_PROJECT_DIR
    PATH="${mock_bin}:${PATH}"
    ISSUE_NUMBER="42"
    REPO_FULL_NAME="test-group/test-project"
    ISSUE_URL="https://gitlab.com/test-group/test-project/-/issues/42"
    CI_SERVER_HOST="gitlab.com"
    FULLSEND_FORGE="gitlab"
    GITLAB_TOKEN="fake-token"
    FULLSEND_PRESCRIPT_OUTPUT="${proto_out}"
  )

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/gl-stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/gl-stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! diff <(printf '%s' "${expected_content}") "${proto_out}" > "${TMPDIR}/gl-proto-diff.log" 2>&1; then
    echo "FAIL: ${test_name} — protocol output mismatch"
    cat "${TMPDIR}/gl-proto-diff.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# GitLab API failure during the existing-PR check must fail open: file stays empty.
run_gitlab_prescript_output_test "protocol-empty-on-gitlab-api-failure" \
  "" \
  0

# --- Regression: forge_retry_transient must be defined for every forge ---
# The pre-code scripts call forge_retry_transient outside the forge-specific
# libs (GitLab MR creation, skip comments). The helper used to be bundled only
# inside the github) arm of the code-ops dispatcher, so under
# FULLSEND_FORGE=gitlab it was undefined ("command not found").
for forge in github gitlab; do
  test_name="code-ops-defines-forge-retry-transient-${forge}"
  if (
    export SCRIPT_DIR FULLSEND_FORGE="${forge}" CI_SERVER_HOST="gitlab.example.com"
    # shellcheck source=lib/code-ops.lib.sh
    source "${SCRIPT_DIR}/lib/code-ops.lib.sh"
    declare -F forge_retry_transient >/dev/null
  ); then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — forge_retry_transient not defined after sourcing code-ops.lib.sh"
    FAILURES=$((FAILURES + 1))
  fi
done

# Bundled mode: the helper must be bundled before the forge dispatch (i.e.
# before the forge-specific libs), not nested inside a single forge arm.
for bundle in pre-code.sh pre-code-jira.sh; do
  test_name="bundle-loads-forge-retry-transient-before-forge-dispatch-${bundle}"
  retry_line=$(grep -n '^# BEGIN bundled: lib/forge-transient-retry.lib.sh' "${SCRIPT_DIR}/${bundle}" | head -1 | cut -d: -f1)
  gh_line=$(grep -n '^# BEGIN bundled: lib/github-code-ops.lib.sh' "${SCRIPT_DIR}/${bundle}" | head -1 | cut -d: -f1)
  if [[ -z "${retry_line}" || -z "${gh_line}" ]] || (( retry_line >= gh_line )); then
    echo "FAIL: ${test_name} — retry lib not bundled ahead of forge-specific libs (retry=${retry_line:-none}, github=${gh_line:-none})"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name}"
  fi
done

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
