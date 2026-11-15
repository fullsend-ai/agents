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
mkdir -p "${MOCK_BIN}"

# Mock gh and curl: record every call.
for tool in gh curl; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> %q\nexit 0\n' "${tool}" "${FORGE_LOG}" > "${MOCK_BIN}/${tool}"
  chmod +x "${MOCK_BIN}/${tool}"
done

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
  if [[ -s "${FORGE_LOG}" ]]; then
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

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
