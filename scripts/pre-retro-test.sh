#!/usr/bin/env bash
# pre-retro-test.sh — Test pre-retro.sh originating-URL validation and
# trigger-context logging.
#
# Uses mock gh and curl commands to assert the pre-script makes no forge calls.
# Run from the repo root: bash scripts/pre-retro-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"
PRE_SCRIPT="$(resolve_agent_script pre-retro "${SCRIPT_DIR}")"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

MOCK_BIN="${TMPDIR}/bin"
FORGE_LOG="${TMPDIR}/forge-calls.log"
OUT="${TMPDIR}/out.log"
# Jira-originated runs write the issue context here; the harness mounts the
# same path. Keeping it inside TMPDIR also stops the suite leaving a context
# file behind on the host.
JIRA_CONTEXT_FILE="${TMPDIR}/retro-jira-context.json"
mkdir -p "${MOCK_BIN}"

# Mock gh: record every call.
printf '#!/usr/bin/env bash
echo "gh $*" >> %q
exit 0
' "${FORGE_LOG}" > "${MOCK_BIN}/gh"
chmod +x "${MOCK_BIN}/gh"

# Mock curl: record every call, and answer tenant_info, issue, and comment endpoints
# when pre-retro fetches the Jira context.
#   JIRA_MOCK_ISSUE_FAIL=1        — the issue read fails (curl error)
#   JIRA_MOCK_COMMENT_FAIL=1      — the comment read fails (curl error)
#   JIRA_MOCK_COMMENT_PAGES=1     — comments span two pages with no total
#   JIRA_MOCK_LONG_DESCRIPTION=1  — a long ADF description with a heading/list
cat > "${MOCK_BIN}/curl" <<CURLEOF
#!/usr/bin/env bash
echo "curl \$*" >> "${FORGE_LOG}"
url=""
for arg in "\$@"; do
  case "\$arg" in
    https://*) url="\$arg" ;;
  esac
done
case "\$url" in
  */_edge/tenant_info)
    echo '{"cloudId":"11111111-2222-3333-4444-555555555555"}'
    ;;
  */rest/api/3/issue/*/comment*)
    if [[ "\${JIRA_MOCK_COMMENT_FAIL:-}" == "1" ]]; then
      echo "curl: (22) The requested URL returned error: 500" >&2
      exit 22
    fi
    if [[ "\${JIRA_MOCK_COMMENT_PAGES:-}" == "1" ]]; then
      # No total, so only the page cap stops the loop.
      echo '{"startAt":0,"maxResults":100,"comments":[{"id":"1","author":{"displayName":"User"},"created":"2026-11-20T00:00:00.000+0000","body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Test comment"}]}]}}]}'
    else
      echo '{"startAt":0,"maxResults":100,"total":1,"comments":[{"id":"1","author":{"displayName":"User"},"created":"2026-11-20T00:00:00.000+0000","body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Test comment"}]}]}}]}'
    fi
    ;;
  */rest/api/3/issue/*)
    if [[ "\${JIRA_MOCK_ISSUE_FAIL:-}" == "1" ]]; then
      echo "curl: (22) The requested URL returned error: 404" >&2
      exit 22
    fi
    if [[ "\${JIRA_MOCK_LONG_DESCRIPTION:-}" == "1" ]]; then
      printf '{"key":"PROJ-123","fields":{"summary":"Test issue","description":{"type":"doc","version":1,"content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Requirement"}]},{"type":"paragraph","content":[{"type":"text","text":"%s"}]}]},"status":{"name":"Open"},"issuetype":{"name":"Task"},"labels":["test"],"project":{"key":"PROJ"}}}' "\$(printf 'long text %.0s' \$(seq 1 400))"
    else
      echo '{"key":"PROJ-123","fields":{"summary":"Test issue","description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Test description"}]}]},"status":{"name":"Open"},"issuetype":{"name":"Task"},"labels":["test"],"project":{"key":"PROJ"}}}'
    fi
    ;;
esac
exit 0
CURLEOF
chmod +x "${MOCK_BIN}/curl"

# run_test NAME EXPECTED_EXIT EXPECTED_PATTERN [VAR=value ...] — run
# pre-retro in a clean environment (GitHub forge by default; later
# VAR=value arguments override it) and check exit code and output.
run_test() {
  local test_name="$1" expected="$2" pattern="$3"
  shift 3
  : > "${FORGE_LOG}"
  local rc=0
  env -i \
    PATH="${MOCK_BIN}:${PATH}" \
    GH_TOKEN="fake-gh-token" \
    GITLAB_TOKEN="fake-gitlab-token" \
    FULLSEND_FORGE="github" \
    "$@" \
    bash "${PRE_SCRIPT}" > "${OUT}" 2>&1 || rc=$?

  if [[ "${rc}" -ne "${expected}" ]]; then
    echo "FAIL: ${test_name} — exit code ${rc}, expected ${expected}"
    cat "${OUT}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -qF -- "${pattern}" "${OUT}"; then
    echo "FAIL: ${test_name} — expected output '${pattern}' not found"
    cat "${OUT}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  # Jira-originated runs make host-side Jira REST reads to fetch issue context;
  # forge calls (gh or non-Jira curl) must never occur.
  local unexpected=0
  if grep -qvE 'curl.*(atlassian\.net|api\.atlassian\.com)' "${FORGE_LOG}" 2>/dev/null; then
    unexpected=1
  elif [[ "${test_name}" != jira-* ]] && [[ -s "${FORGE_LOG}" ]]; then
    unexpected=1
  fi
  if [[ "${unexpected}" -eq 1 ]]; then
    echo "FAIL: ${test_name} — unexpected forge calls:"
    cat "${FORGE_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_test_unbound_forge_tokens() {
  local test_name="$1" expected="$2" pattern="$3"
  shift 3
  : > "${FORGE_LOG}"
  local rc=0
  env -i \
    PATH="${MOCK_BIN}:${PATH}" \
    FULLSEND_FORGE="github" \
    "$@" \
    bash "${PRE_SCRIPT}" > "${OUT}" 2>&1 || rc=$?

  if [[ "${rc}" -ne "${expected}" ]]; then
    echo "FAIL: ${test_name} — exit code ${rc}, expected ${expected}"
    cat "${OUT}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -qF -- "${pattern}" "${OUT}"; then
    echo "FAIL: ${test_name} — expected output '${pattern}' not found"
    cat "${OUT}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  # Jira-originated runs make host-side Jira REST reads to fetch issue context;
  # forge calls (gh or non-Jira curl) must never occur.
  local unexpected=0
  if grep -qvE 'curl.*(atlassian\.net|api\.atlassian\.com)' "${FORGE_LOG}" 2>/dev/null; then
    unexpected=1
  elif [[ "${test_name}" != jira-* ]] && [[ -s "${FORGE_LOG}" ]]; then
    unexpected=1
  fi
  if [[ "${unexpected}" -eq 1 ]]; then
    echo "FAIL: ${test_name} — unexpected forge calls:"
    cat "${FORGE_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# --- Required environment ---

run_test "missing-originating-url-fails" 1 "ORIGINATING_URL is required"

run_test "missing-forge-fails" 1 "FULLSEND_FORGE must be set" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42" FULLSEND_FORGE=

run_test "invalid-forge-fails" 1 "invalid FULLSEND_FORGE" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42" FULLSEND_FORGE=bitbucket

# --- GitHub ---

run_test "github-pr-url-automatic" 0 "Retro triggered automatically (PR close)." \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"

run_test "github-pr-url-logs-target" 0 "::notice::Retro target: https://github.com/test-org/test-repo/pull/42" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"

run_test "github-issue-url-on-demand" 0 "Retro triggered on-demand with comment." \
  ORIGINATING_URL="https://github.com/test-org/test-repo/issues/7" RETRO_COMMENT="/retro why did review miss this?"

run_test "github-validation-complete" 0 "Pre-retro validation complete." \
  ORIGINATING_URL="https://github.com/test-org/test-repo/issues/7"

run_test "github-malformed-url-fails" 1 "ORIGINATING_URL does not match expected pattern" \
  ORIGINATING_URL="https://github.com/test-org/test-repo"

run_test "github-non-numeric-number-fails" 1 "does not match expected pattern" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/abc"

run_test "github-other-host-fails" 1 "does not match expected pattern" \
  ORIGINATING_URL="https://evil.example/test-org/test-repo/pull/42"

run_test "github-trailing-path-fails" 1 "does not match expected pattern" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42/files"

run_test "github-rejects-gitlab-url" 1 "does not match expected pattern" \
  ORIGINATING_URL="https://gitlab.com/group/project/-/merge_requests/42"

# A workflow-command injection attempt is rejected and sanitized in the log.
run_test "github-injection-sanitized" 1 "%3A%3Awarning%3A%3Ax" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42::warning::x"

# --- GitLab ---

run_test "gitlab-mr-url-subgroup" 0 "Retro target: https://gitlab.example.com/group/sub/project/-/merge_requests/42" \
  FULLSEND_FORGE=gitlab CI_SERVER_HOST=gitlab.example.com \
  ORIGINATING_URL="https://gitlab.example.com/group/sub/project/-/merge_requests/42"

run_test "gitlab-issue-url-on-demand" 0 "Retro triggered on-demand with comment." \
  FULLSEND_FORGE=gitlab CI_SERVER_HOST=gitlab.example.com RETRO_COMMENT="/retro" \
  ORIGINATING_URL="https://gitlab.example.com/group/project/-/issues/7"

run_test "gitlab-host-case-insensitive" 0 "Pre-retro validation complete." \
  FULLSEND_FORGE=gitlab CI_SERVER_HOST=GitLab.Example.com \
  ORIGINATING_URL="https://gitlab.example.com/group/project/-/issues/7"

run_test "gitlab-malformed-url-fails" 1 "does not match expected GitLab pattern" \
  FULLSEND_FORGE=gitlab CI_SERVER_HOST=gitlab.example.com \
  ORIGINATING_URL="https://gitlab.example.com/group/project/issues/7"

run_test "gitlab-top-level-project-fails" 1 "does not match expected GitLab pattern" \
  FULLSEND_FORGE=gitlab CI_SERVER_HOST=gitlab.example.com \
  ORIGINATING_URL="https://gitlab.example.com/project/-/issues/7"

run_test "gitlab-untrusted-host-fails" 1 "does not match CI_SERVER_HOST" \
  FULLSEND_FORGE=gitlab CI_SERVER_HOST=gitlab.example.com \
  ORIGINATING_URL="https://evil.example/group/project/-/issues/7"

run_test "gitlab-no-ci-server-host-fails-closed" 1 "CI_SERVER_HOST is not set" \
  FULLSEND_FORGE=gitlab \
  ORIGINATING_URL="https://gitlab.example.com/group/project/-/issues/7"

run_test "gitlab-invalid-ci-server-host-fails" 1 "CI_SERVER_HOST contains invalid characters" \
  FULLSEND_FORGE=gitlab CI_SERVER_HOST="gitlab.example.com/evil" \
  ORIGINATING_URL="https://gitlab.example.com/group/project/-/issues/7"

# --- Jira tracker ---

run_test "jira-missing-fullsend-dir-fails" 1 "FULLSEND_DIR must be set when FULLSEND_TRACKER=jira" \
  FULLSEND_TRACKER=jira JIRA_TOKEN="test-token" JIRA_BASE_URL="https://test.atlassian.net" \
  RETRO_JIRA_PROJECT="PROJ" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"

run_test "jira-pr-url-with-fullsend-dir" 0 "Pre-retro validation complete." \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"

# Client-credentials runs must not mint at source time. Pre-retro makes no
# Jira call, so a mint here is a live token exchange performed for nothing
# (and, before the fix, a transient Atlassian failure failed the pre-step).
# run_test fails on any curl invocation, so the exchange is caught here even
# though the mock would answer it.
run_test "jira-client-credentials-pre-retro-no-mint" 0 "Pre-retro validation complete." \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" \
  FULLSEND_JIRA_CLIENT_ID="client-id" FULLSEND_JIRA_CLIENT_SECRET="client-secret" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"

run_test "jira-issue-url" 0 "Retro target: https://test.atlassian.net/browse/PROJ-123" \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"

run_test "jira-token-masked" 0 "::add-mask::secret-jira-token" \
  GITHUB_ACTIONS=true \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="secret-jira-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"

run_test_unbound_forge_tokens "jira-origin-gha-no-forge-token" 0 "::add-mask::secret-jira-token" \
  GITHUB_ACTIONS=true \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="secret-jira-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"

run_test_unbound_forge_tokens "jira-origin-gha-gitlab-forge-no-token" 0 "::add-mask::secret-jira-token" \
  GITHUB_ACTIONS=true FULLSEND_FORGE=gitlab \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="secret-jira-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"

run_test "jira-token-not-masked-without-gha" 0 "Retro target: https://test.atlassian.net/browse/PROJ-123" \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="secret-jira-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"
if grep -qF "::add-mask::secret-jira-token" "${OUT}" 2>/dev/null; then
  echo "FAIL: jira-token-not-masked-without-gha — token masked when GITHUB_ACTIONS is unset"
  FAILURES=$((FAILURES + 1))
fi

run_test "jira-untrusted-host-fails" 1 "ORIGINATING_URL Jira host 'evil.example' is not in the allowed host list" \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  ORIGINATING_URL="https://evil.example/browse/PROJ-123"

run_test "jira-tenant-mismatch-fails" 1 "does not match JIRA_BASE_URL" \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  ORIGINATING_URL="https://other.atlassian.net/browse/PROJ-123"

# RETRO_JIRA_MAX_PAGES bounds a bash arithmetic loop, so anything outside a
# plain positive integer is refused: 0 silently truncates every duplicate
# search, and a non-numeric value would be evaluated as arithmetic.
run_test "jira-zero-max-pages-fails" 1 "RETRO_JIRA_MAX_PAGES must be a positive integer" \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" RETRO_JIRA_MAX_PAGES=0 \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"

run_test "jira-nonnumeric-max-pages-fails" 1 "RETRO_JIRA_MAX_PAGES must be a positive integer" \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" "RETRO_JIRA_MAX_PAGES=x[1]" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"

run_test "jira-summary-only-forge-no-credentials" 0 "Pre-retro validation complete." \
  FULLSEND_TRACKER=jira RETRO_MODE="summary_only" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"

# --- Jira-originated host-side context file ---
#
# The context file is the only Jira data the sandbox gets, and it carries
# untrusted issue text, so its content and its failure modes are asserted
# here rather than left to the mocked happy path above.

# check_context NAME JQ_FILTER EXPECTED — assert the written context file.
check_context() {
  local test_name="$1" filter="$2" expected="$3" actual=""
  actual=$(jq -r "${filter}" "${JIRA_CONTEXT_FILE}" 2>/dev/null) || actual=""
  if [[ "${actual}" == "${expected}" ]]; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected '${filter}' = '${expected}', got '${actual}'"
    cat "${JIRA_CONTEXT_FILE}" 2>/dev/null || true
    FAILURES=$((FAILURES + 1))
  fi
}

check_context_contains() {
  local test_name="$1" pattern="$2"
  if grep -qF -- "${pattern}" "${JIRA_CONTEXT_FILE}" 2>/dev/null; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected '${pattern}' in the context file"
    cat "${JIRA_CONTEXT_FILE}" 2>/dev/null || true
    FAILURES=$((FAILURES + 1))
  fi
}

# The harness mounts ${RETRO_JIRA_CONTEXT_FILE}, so a Jira-originated run
# without it would mount nothing and analyze blind. Fail closed instead.
run_test "jira-context-file-unset-fails" 1 "RETRO_JIRA_CONTEXT_FILE must be set for a Jira-originated retro" \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"

# An unreadable issue fails the run: a retrospective must not analyze a work
# item it cannot see.
run_test "jira-context-issue-read-fails-closed" 1 "failed to fetch Jira issue PROJ-123" \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" JIRA_MOCK_ISSUE_FAIL=1 \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"

run_test "jira-context-comment-read-fails-closed" 1 "failed to fetch Jira issue PROJ-123" \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" JIRA_MOCK_COMMENT_FAIL=1 \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"

# Flat description and comment, complete list, no truncation.
run_test "jira-context-written" 0 "Pre-retro validation complete." \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"
check_context "jira-context-key" ".issue.key" "PROJ-123"
check_context "jira-context-url" ".issue.url" "https://test.atlassian.net/browse/PROJ-123"
check_context "jira-context-description-flattened" ".issue.description" "Test description"
check_context "jira-context-comment-flattened" ".comments[0].body" "Test comment"
check_context "jira-context-comments-not-truncated" ".comments_truncated" "false"
check_context "jira-context-description-not-truncated" ".issue.description_truncated" "false"

# ADF headings and lists become readable text instead of raw JSON.
run_test "jira-context-adf-description" 0 "Pre-retro validation complete." \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" JIRA_MOCK_LONG_DESCRIPTION=1 \
  RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS=100 \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"
check_context_contains "jira-context-adf-heading" "## Requirement"
check_context "jira-context-description-clipped" ".issue.description_truncated" "true"
check_context_contains "jira-context-description-clip-marker" "(truncated)"

# An individual comment body over RETRO_JIRA_CONTEXT_COMMENT_CHARS is clipped
# and marked, without claiming the comment list itself is incomplete.
run_test "jira-context-comment-clipped" 0 "Pre-retro validation complete." \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" RETRO_JIRA_CONTEXT_COMMENT_CHARS=5 \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"
check_context_contains "jira-context-comment-clip-marker" "(truncated)"
check_context "jira-context-comment-clip-not-list-truncation" ".comments_truncated" "false"

# Over RETRO_JIRA_CONTEXT_MAX_BYTES the oldest comments are dropped and the file
# says so, so the agent reports the gap instead of trusting a partial list.
run_test "jira-context-byte-cap-truncated" 0 "Pre-retro validation complete." \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" RETRO_JIRA_CONTEXT_MAX_BYTES=64 \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"
check_context "jira-context-byte-cap-drops-comments" ".comments | length" "0"
check_context "jira-context-byte-cap-flag" ".comments_truncated" "true"

# The page cap is the other truncation path, and it must set the same flag: the
# fetch cannot tell, from a cap alone, what it did not read.
run_test "jira-context-page-cap-truncated" 0 "Pre-retro validation complete." \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" RETRO_JIRA_CONTEXT_MAX_PAGES=1 \
  JIRA_MOCK_COMMENT_PAGES=1 \
  ORIGINATING_URL="https://test.atlassian.net/browse/PROJ-123"
check_context "jira-context-page-cap-flag" ".comments_truncated" "true"
if grep -qF "orderBy=created" "${FORGE_LOG}" 2>/dev/null; then
  echo "PASS: jira-context-comment-order-explicit"
else
  echo "FAIL: jira-context-comment-order-explicit — comment fetch did not pass orderBy=created"
  cat "${FORGE_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# A reused host keeps the context file between runs, and the harness uploads it
# on every retro run. A forge-originated run must not leave an earlier Jira
# issue's text where the mount will find it.
printf '{"source":"jira","issue":{"key":"OLD-1"}}' > "${JIRA_CONTEXT_FILE}"
run_test "jira-context-stale-removed-on-forge-run" 0 "Pre-retro validation complete." \
  FULLSEND_TRACKER=jira FULLSEND_DIR="${TMPDIR}/dot-fullsend" JIRA_TOKEN="test-token" \
  JIRA_BASE_URL="https://test.atlassian.net" RETRO_JIRA_PROJECT="PROJ" \
  RETRO_JIRA_CONTEXT_FILE="${JIRA_CONTEXT_FILE}" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"
if [[ -e "${JIRA_CONTEXT_FILE}" ]]; then
  echo "FAIL: jira-context-stale-removed-on-forge-run — stale context file left in place"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-context-stale-file-gone"
fi

# RETRO_MODE is validated before the tracker library acts on it, so a typo is
# rejected with its own message instead of a missing-credential error.
run_test "jira-invalid-retro-mode-fails" 1 "RETRO_MODE must be 'all', 'summary_only', or 'issues_only'" \
  FULLSEND_TRACKER=jira RETRO_MODE="summary-only" \
  ORIGINATING_URL="https://github.com/test-org/test-repo/pull/42"

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
