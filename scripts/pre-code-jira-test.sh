#!/usr/bin/env bash
# pre-code-jira-test.sh — Test pre-code-jira.sh Jira-source pre-script.
#
# Validates URL parsing and error handling, and the existing human-PR,
# child-issue, and --force checks.  gh, curl, and fullsend are stubbed;
# the stubs read MOCK_* env vars and record their calls under TMPDIR.
# Run from the repo root: bash scripts/pre-code-jira-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

PRE_SCRIPT="$(resolve_agent_script pre-code-jira "${SCRIPT_DIR}")"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

PRESCRIPT_OUT="${TMPDIR}/prescript.out"
FULLSEND_CALLS="${TMPDIR}/fullsend-calls.log"
CURL_ARGV_LOG="${TMPDIR}/curl-argv.log"
PAYLOAD_DIR="${TMPDIR}/fullsend-dir/dispatch"

# --- Helpers ---

# build_mock creates mock binaries for gh, curl, fullsend, git, python3.
build_mock() {
  local mock_bin="${TMPDIR}/bin"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"

  # Mock gh: `gh pr list` prints MOCK_GH_PRS (default: no PRs).
  cat > "${mock_bin}/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
  [[ "${MOCK_GH_FAIL:-}" == "1" ]] && exit 1
  printf '%s\n' "${MOCK_GH_PRS:-[]}"
fi
exit 0
GHEOF
  chmod +x "${mock_bin}/gh"

  # Mock curl: Jira JQL search and GitLab MR listing.
  cat > "${mock_bin}/curl" <<'CURLEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_ARGV_LOG}"
data=""
prev=""
for arg in "$@"; do
  [[ "${prev}" == "--data" ]] && data="${arg}"
  prev="${arg}"
done
for arg in "$@"; do
  case "${arg}" in
    https://auth.atlassian.com/oauth/token)
      # OAuth 2.0 client-credentials token request: the body comes on stdin.
      cat > /dev/null
      printf '{"access_token":"minted-access-token","expires_in":3600}\n200'
      exit 0
      ;;
    */rest/api/3/search/jql)
      [[ "${MOCK_JIRA_CHILD_FAIL:-}" == "1" ]] && exit 22
      # MOCK_JIRA_EXPECT_API_URL: fail unless the call goes to that base.
      if [[ -n "${MOCK_JIRA_EXPECT_API_URL:-}" && "${arg}" != "${MOCK_JIRA_EXPECT_API_URL}/rest/api/3/search/jql" ]]; then
        exit 22
      fi
      # MOCK_JIRA_EXPECT_BEARER=1: fail unless service-account Bearer auth
      # was used.
      if [[ "${MOCK_JIRA_EXPECT_BEARER:-}" == "1" && " $* " != *" --oauth2-bearer "* ]]; then
        exit 22
      fi
      # MOCK_JIRA_SUBTASKS_ONLY=1: every child is a subtask, so a query
      # that excludes subtask types finds none, as Jira would.
      if [[ "${MOCK_JIRA_SUBTASKS_ONLY:-}" == "1" && "${data}" == *"issuetype not in subTaskIssueTypes()"* ]]; then
        printf '{"issues":[]}\n'
        exit 0
      fi
      printf '%s\n' "${MOCK_JIRA_CHILDREN:-{\"issues\":[]\}}"
      exit 0
      ;;
    */merge_requests*page=1)
      printf '%s\n' "${MOCK_GL_MRS:-[]}"
      exit 0
      ;;
    */merge_requests*)
      printf '[]\n'
      exit 0
      ;;
  esac
done
exit 7
CURLEOF
  chmod +x "${mock_bin}/curl"

  # Mock fullsend: records the post-comment call and its stdin.
  cat > "${mock_bin}/fullsend" <<'FSEOF'
#!/usr/bin/env bash
{
  echo "ARGS: $*"
  echo "ENV: token=${FULLSEND_JIRA_TOKEN-unset} id=${FULLSEND_JIRA_CLIENT_ID-unset} secret=${FULLSEND_JIRA_CLIENT_SECRET:+set}"
  echo "BODY:"
  cat
} >> "${FULLSEND_CALLS}"
exit "${MOCK_FULLSEND_EXIT:-0}"
FSEOF
  chmod +x "${mock_bin}/fullsend"

  # Mock git (needed for pre-commit tool resolution)
  cat > "${mock_bin}/git" <<'GITEOF'
#!/usr/bin/env bash
exit 1
GITEOF
  chmod +x "${mock_bin}/git"

  # Mock python3 (needed for resolve-precommit-tools.py)
  cat > "${mock_bin}/python3" <<'PYEOF'
#!/usr/bin/env bash
exit 1
PYEOF
  chmod +x "${mock_bin}/python3"

  echo "${mock_bin}"
}

# Base env for all tests — Jira→GitHub composition.
base_env() {
  local mock_bin="$1"
  echo "PATH=${mock_bin}:${PATH}"
  echo "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42"
  echo "JIRA_USER_EMAIL=bot@acme.com"
  echo "JIRA_TOKEN=fake-jira-token"
  echo "JIRA_BASE_URL=https://acme.atlassian.net"
  echo "REPO_FULL_NAME=test-org/test-repo"
  echo "FULLSEND_FORGE=github"
  echo "GH_TOKEN=fake-gh-token"
  echo "GITHUB_OUTPUT=/dev/null"
  echo "GITHUB_PATH=/dev/null"
  echo "GITHUB_WORKSPACE=${TMPDIR}/workspace"
  echo "FULLSEND_DIR=${TMPDIR}/fullsend-dir"
  echo "FULLSEND_PRESCRIPT_OUTPUT=${PRESCRIPT_OUT}"
  echo "FULLSEND_CALLS=${FULLSEND_CALLS}"
  echo "CURL_ARGV_LOG=${CURL_ARGV_LOG}"
  echo "COMMENT_BODY="
  echo "CODE_FORCE="
}

# run_script EXTRA_ENV — run the pre-script; sets RUN_EXIT.
run_script() {
  local extra_env="${1:-}"

  local mock_bin
  mock_bin="$(build_mock)"
  rm -f "${PRESCRIPT_OUT}" "${FULLSEND_CALLS}" "${CURL_ARGV_LOG}"

  local env_cmd=(env)

  # Read base env
  while IFS= read -r kv; do
    [[ -n "${kv}" ]] && env_cmd+=("${kv}")
  done <<< "$(base_env "${mock_bin}")"

  # Add extra env vars
  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  # A multi-line COMMENT_BODY cannot go through the line-based EXTRA_ENV.
  if [[ -n "${TEST_COMMENT_BODY:-}" ]]; then
    env_cmd+=("COMMENT_BODY=${TEST_COMMENT_BODY}")
  fi

  RUN_EXIT=0
  # RUN_XTRACE=1 runs the script under bash -x.
  "${env_cmd[@]}" bash ${RUN_XTRACE:+-x} "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || RUN_EXIT=$?
}

run_test() {
  local test_name="$1"
  local expect_exit="$2"
  local expected_stdout="$3"
  local extra_env="${4:-}"

  run_script "${extra_env}"

  if [[ ${RUN_EXIT} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${RUN_EXIT}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_stdout}" ]]; then
    if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
      echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
      echo "Actual stdout:"
      cat "${TMPDIR}/stdout.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# run_skip_test NAME EXPECT_SKIP EXPECTED_TEXT EXTRA_ENV — run the script,
# require exit 0, and check whether it wrote skipped=true. EXPECTED_TEXT
# (optional) must appear in the prescript output (skip) or stdout (no skip).
run_skip_test() {
  local test_name="$1"
  local expect_skip="$2"
  local expected_text="$3"
  local extra_env="${4:-}"

  run_script "${extra_env}"

  if [[ ${RUN_EXIT} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected exit 0, got ${RUN_EXIT}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local skipped=false
  if [[ -f "${PRESCRIPT_OUT}" ]] && grep -qx 'skipped=true' "${PRESCRIPT_OUT}"; then
    skipped=true
  fi
  if [[ "${skipped}" != "${expect_skip}" ]]; then
    echo "FAIL: ${test_name} — expected skipped=${expect_skip}, got ${skipped}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_text}" ]]; then
    local where="${TMPDIR}/stdout.log"
    [[ "${expect_skip}" == "true" ]] && where="${PRESCRIPT_OUT}"
    if ! grep -qF -- "${expected_text}" "${where}" 2>/dev/null; then
      echo "FAIL: ${test_name} — expected '${expected_text}' not found in $(basename "${where}")"
      cat "${where}" 2>/dev/null || true
      cat "${TMPDIR}/stdout.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# write_payload JSON — write the dispatch event payload; clear_payload removes it.
write_payload() {
  mkdir -p "${PAYLOAD_DIR}"
  printf '%s' "$1" > "${PAYLOAD_DIR}/event-payload.json"
}
clear_payload() {
  rm -f "${PAYLOAD_DIR}/event-payload.json"
}

HUMAN_PR_URL_BODY='[{"number":7,"title":"Fix the thing","body":"Change details.\n\nRelated to https://acme.atlassian.net/browse/PROJ-42","url":"https://github.com/test-org/test-repo/pull/7","author":{"login":"alice","is_bot":false}}]'
HUMAN_PR_PREFIX_KEY='[{"number":8,"title":"PROJ-4: other work","body":"See PROJ-421","url":"https://github.com/test-org/test-repo/pull/8","author":{"login":"alice","is_bot":false}}]'
BOT_PR='[{"number":9,"title":"fix(PROJ-42): agent fix","body":"Related to https://acme.atlassian.net/browse/PROJ-42","url":"https://github.com/test-org/test-repo/pull/9","author":{"login":"app/fullsend-ai-coder","is_bot":true}}]'
HAS_CHILDREN='{"issues":[{"id":"10001","key":"PROJ-43"}]}'

# --- Test cases: URL and host validation ---

# Valid Jira→GitHub composition succeeds.
run_test "valid-jira-github-succeeds" \
  0 \
  "Jira source:"

# Valid Jira→GitLab composition also works.
run_test "valid-jira-gitlab-succeeds" \
  0 \
  "Jira source:" \
  "FULLSEND_FORGE=gitlab"

# Invalid Jira URL pattern is rejected.
run_test "invalid-jira-url-rejected" \
  1 \
  "does not match expected Jira pattern" \
  "ISSUE_URL=https://github.com/org/repo/issues/1"

# Non-atlassian.net host is rejected.
run_test "non-atlassian-host-rejected" \
  1 \
  "not in the allowed host list" \
  "ISSUE_URL=https://evil.example.com/browse/PROJ-42"

# JIRA_BASE_URL mismatch is rejected.
run_test "base-url-mismatch-rejected" \
  1 \
  "does not match ISSUE_URL host" \
  "JIRA_BASE_URL=https://other.atlassian.net"

# JIRA_BASE_URL with trailing slash normalizes and matches.
run_test "base-url-trailing-slash-normalizes" \
  0 \
  "Jira source:" \
  "JIRA_BASE_URL=https://acme.atlassian.net/"

# Script succeeds without JIRA_USER_EMAIL.
run_test "no-jira-email-still-succeeds" \
  0 \
  "Jira source:" \
  "JIRA_USER_EMAIL="

# Script succeeds without JIRA_TOKEN.
run_test "no-jira-token-still-succeeds" \
  0 \
  "Jira source:" \
  "JIRA_TOKEN="

# --- Test cases: existing human-PR check ---

run_skip_test "human-pr-with-jira-url-skips" \
  true \
  "reason=open PR #7 by @alice already addresses PROJ-42" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"

# The skip comment goes to the Jira issue with the fixed marker and PR URL.
if grep -qF -- "--marker <!-- fullsend:pre-code-jira-skip -->" "${FULLSEND_CALLS}" 2>/dev/null \
   && grep -qF -- "--number 42" "${FULLSEND_CALLS}" \
   && grep -qF "https://github.com/test-org/test-repo/pull/7" "${FULLSEND_CALLS}" \
   && grep -qF "/fs-code --force" "${FULLSEND_CALLS}"; then
  echo "PASS: human-pr-skip-posts-sticky-jira-comment"
else
  echo "FAIL: human-pr-skip-posts-sticky-jira-comment — expected sticky comment call"
  cat "${FULLSEND_CALLS}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

run_skip_test "human-pr-key-prefix-does-not-match" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42
MOCK_GH_PRS=${HUMAN_PR_PREFIX_KEY}"

run_skip_test "human-pr-key-letter-suffix-does-not-match" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42
MOCK_GH_PRS=[{\"number\":5,\"title\":\"PROJ-42abc work\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/5\",\"author\":{\"login\":\"alice\"}}]"

run_skip_test "human-pr-key-underscore-suffix-does-not-match" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42
MOCK_GH_PRS=[{\"number\":5,\"title\":\"PROJ-42_work\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/5\",\"author\":{\"login\":\"alice\"}}]"

run_skip_test "human-pr-key-leading-underscore-does-not-match" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42
MOCK_GH_PRS=[{\"number\":5,\"title\":\"prefix_PROJ-42 work\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/5\",\"author\":{\"login\":\"alice\"}}]"

run_skip_test "human-pr-shorter-key-not-matching-longer-issue-key" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-123
MOCK_GH_PRS=[{\"number\":5,\"title\":\"PROJ-12 work\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/5\",\"author\":{\"login\":\"alice\"}}]"

run_skip_test "bot-pr-only-does-not-skip" \
  false \
  "No existing human PRs found" \
  "MOCK_GH_PRS=${BOT_PR}"

run_skip_test "custom-app-set-bot-pr-does-not-skip" \
  false \
  "No existing human PRs found" \
  "FULLSEND_APP_SET=custom-app
MOCK_GH_PRS=[{\"number\":9,\"title\":\"PROJ-42\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/9\",\"author\":{\"login\":\"app/custom-app\"}}]"

run_skip_test "third-party-bot-pr-does-not-skip" \
  false \
  "No existing human PRs found" \
  "MOCK_GH_PRS=[{\"number\":11,\"title\":\"chore: bump deps for PROJ-42\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/11\",\"author\":{\"login\":\"app/dependabot\",\"is_bot\":true}}]"

run_skip_test "human-pr-lowercase-key-skips" \
  true \
  "reason=open PR #12 by @alice" \
  "MOCK_GH_PRS=[{\"number\":12,\"title\":\"fix/proj-42-retry\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/12\",\"author\":{\"login\":\"alice\",\"is_bot\":false}}]"

run_skip_test "human-pr-force-on-line-1-does-not-skip" \
  false \
  "Force override" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
COMMENT_BODY=/fs-code --force"

TEST_COMMENT_BODY=$'/fs-code\n--force'
run_skip_test "human-pr-force-on-line-2-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
TEST_COMMENT_BODY=""

run_skip_test "human-pr-code-force-does-not-skip" \
  false \
  "Force override" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
CODE_FORCE=true"

write_payload '{"comment":{"body":"/fs-code --force\r\nplease"},"_normalized_event":{"transition":{"comment":{"command":"/fs-code","instruction":"--force"}}}}'
run_skip_test "human-pr-payload-comment-force-does-not-skip" \
  false \
  "Force override" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
clear_payload

write_payload '{"comment":{"body":"/fs-code\n--force"}}'
run_skip_test "human-pr-payload-force-on-line-2-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
clear_payload

write_payload '{"_normalized_event":{"transition":{"comment":{"command":"/fs-code","instruction":"--force"}}}}'
run_skip_test "human-pr-payload-instruction-force-does-not-skip" \
  false \
  "Force override" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
clear_payload

write_payload '{"_normalized_event":{"transition":{"kind":"label_changed","label":{"name":"ready-to-code","action":"added"}}}}'
run_skip_test "human-pr-label-trigger-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
clear_payload

run_skip_test "human-pr-jira-comment-failure-still-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
MOCK_FULLSEND_EXIT=1"

run_skip_test "human-pr-no-jira-token-still-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
JIRA_TOKEN="

run_skip_test "pr-list-failure-fails-open" \
  false \
  "failing open" \
  "MOCK_GH_FAIL=1"

run_skip_test "no-gh-token-skips-pr-check" \
  false \
  "No github token set — skipping existing-PR check" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
GH_TOKEN="

run_skip_test "gitlab-human-mr-skips" \
  true \
  "open PR !3 by @bob already addresses PROJ-42" \
  "FULLSEND_FORGE=gitlab
GITLAB_TOKEN=fake-gl-token
CI_SERVER_HOST=gitlab.example.com
MOCK_GL_MRS=[{\"iid\":3,\"title\":\"PROJ-42 fix\",\"description\":\"\",\"web_url\":\"https://gitlab.example.com/g/p/-/merge_requests/3\",\"author\":{\"username\":\"bob\"}}]"

# --- Test cases: child-issue check ---

run_skip_test "issue-with-children-skips" \
  true \
  "reason=PROJ-42 has child issue(s)" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}"

run_skip_test "issue-with-only-subtasks-does-not-skip" \
  false \
  "No child issues found" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
MOCK_JIRA_SUBTASKS_ONLY=1"

run_skip_test "issue-with-children-force-does-not-skip" \
  false \
  "Force override" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
COMMENT_BODY=/fs-code --force"

run_skip_test "child-query-failure-does-not-skip" \
  false \
  "::warning::Could not read child issues of PROJ-42" \
  "MOCK_JIRA_CHILD_FAIL=1"

run_skip_test "service-account-token-only-runs-child-check" \
  true \
  "reason=PROJ-42 has child issue(s)" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
MOCK_JIRA_EXPECT_BEARER=1
JIRA_USER_EMAIL="

run_skip_test "no-jira-token-skips-child-check" \
  false \
  "No Jira credentials set — skipping child-issue check" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
JIRA_TOKEN="

run_skip_test "no-children-does-not-skip" \
  false \
  "No child issues found"

# --- Test cases: OAuth 2.0 client credentials (#1926) ---

CLIENT_SECRET_VALUE="client-secret-DO-NOT-LEAK"
GATEWAY_URL="https://api.atlassian.com/ex/jira/cloud-1"

# Client credentials only: the child check sends a minted Bearer token to
# JIRA_API_URL, and the skip comment's CLI call gets the client variables.
run_skip_test "client-credentials-runs-child-check" \
  true \
  "reason=PROJ-42 has child issue(s)" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
MOCK_JIRA_EXPECT_BEARER=1
MOCK_JIRA_EXPECT_API_URL=${GATEWAY_URL}
JIRA_TOKEN=
JIRA_USER_EMAIL=
JIRA_API_URL=${GATEWAY_URL}
FULLSEND_JIRA_CLIENT_ID=client-id-1
FULLSEND_JIRA_CLIENT_SECRET=${CLIENT_SECRET_VALUE}"
if grep -F -- "--oauth2-bearer minted-access-token " "${CURL_ARGV_LOG}" \
     | grep -qF " ${GATEWAY_URL}/rest/api/3/search/jql " \
   && grep -qx "::add-mask::minted-access-token" "${TMPDIR}/stdout.log" \
   && grep -qx "ENV: token=unset id=client-id-1 secret=set" "${FULLSEND_CALLS}" \
   && ! grep -qF "${CLIENT_SECRET_VALUE}" "${CURL_ARGV_LOG}" "${FULLSEND_CALLS}" "${TMPDIR}/stdout.log"; then
  echo "PASS: client-credentials-minted-token-and-cli-env"
else
  echo "FAIL: client-credentials-minted-token-and-cli-env — expected minted Bearer to JIRA_API_URL, a mask, client vars for the CLI, and no secret in argv or output"
  cat "${CURL_ARGV_LOG}" "${FULLSEND_CALLS}" "${TMPDIR}/stdout.log" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# Under bash -x, the client secret must not appear on any traced line.
XTRACE_SECRET_VALUE="xtrace-secret-Q7Zk9wPv"
RUN_XTRACE=1 run_skip_test "client-credentials-xtrace-runs-child-check" \
  true \
  "reason=PROJ-42 has child issue(s)" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
MOCK_JIRA_EXPECT_BEARER=1
MOCK_JIRA_EXPECT_API_URL=${GATEWAY_URL}
JIRA_TOKEN=
JIRA_USER_EMAIL=
JIRA_API_URL=${GATEWAY_URL}
FULLSEND_JIRA_CLIENT_ID=client-id-1
FULLSEND_JIRA_CLIENT_SECRET=${XTRACE_SECRET_VALUE}"
if grep -q '^+' "${TMPDIR}/stdout.log" \
   && ! grep -qF "${XTRACE_SECRET_VALUE}" "${TMPDIR}/stdout.log" "${CURL_ARGV_LOG}" "${FULLSEND_CALLS}"; then
  echo "PASS: client-credentials-xtrace-no-secret"
else
  echo "FAIL: client-credentials-xtrace-no-secret — expected a trace and no client secret in it"
  grep -nF "${XTRACE_SECRET_VALUE}" "${TMPDIR}/stdout.log" 2>/dev/null | head -5 || true
  FAILURES=$((FAILURES + 1))
fi

run_test "client-credentials-without-api-url-fails" \
  1 \
  "JIRA_API_URL (the Atlassian API gateway URL) must be set" \
  "JIRA_TOKEN=
FULLSEND_JIRA_CLIENT_ID=client-id-1
FULLSEND_JIRA_CLIENT_SECRET=${CLIENT_SECRET_VALUE}"

run_test "token-and-client-credentials-fail" \
  1 \
  "not both" \
  "JIRA_API_URL=${GATEWAY_URL}
FULLSEND_JIRA_CLIENT_ID=client-id-1
FULLSEND_JIRA_CLIENT_SECRET=${CLIENT_SECRET_VALUE}"

run_test "one-client-variable-fails" \
  1 \
  "must be set together" \
  "JIRA_TOKEN=
JIRA_API_URL=${GATEWAY_URL}
FULLSEND_JIRA_CLIENT_ID=client-id-1"

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
