#!/usr/bin/env bash
# pre-prioritize-test.sh — Test pre-prioritize.sh forge dispatch and URL validation.
#
# Run from the repo root: bash scripts/pre-prioritize-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"
PRE_SCRIPT="$(resolve_agent_script pre-prioritize "${SCRIPT_DIR}")"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"

# Mock gh: accept any call.
printf '#!/usr/bin/env bash\nexit 0\n' > "${MOCK_BIN}/gh"
chmod +x "${MOCK_BIN}/gh"

# Mock curl: return bot user identity for /user, accept everything else.
cat > "${MOCK_BIN}/curl" <<'CURLMOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "${arg}" =~ /user$ ]]; then
    echo '{"username":"fullsend-bot","id":12345}'
    exit 0
  fi
done
exit 0
CURLMOCK
chmod +x "${MOCK_BIN}/curl"

export PATH="${MOCK_BIN}:${PATH}"

run_test() {
  local test_name="$1"
  local forge="$2"
  local issue_url="$3"
  local expected_pattern="${4:-}"
  local expect_failure="${5:-false}"
  local extra_env="${6:-}"

  local env_cmd=(
    env -u CI_SERVER_HOST
    FULLSEND_FORGE="${forge}"
    ISSUE_URL="${issue_url}"
    GH_TOKEN="fake-token"
    GITLAB_TOKEN="fake-gitlab-token"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    if [[ -n "${expected_pattern}" ]] && ! grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout-${test_name}.log"; then
      echo "FAIL: ${test_name} — expected error pattern '${expected_pattern}' not found"
      cat "${TMPDIR}/stdout-${test_name}.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure)"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_pattern}" ]] && ! grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_pattern}' not found"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- GitHub forge tests ---

run_test "github-valid-url" \
  "github" \
  "https://github.com/test-org/test-repo/issues/42" \
  "Issue URL validated."

run_test "github-malformed-url-fails" \
  "github" \
  "https://github.com/not-an-issue-url" \
  "does not match expected pattern" \
  "true"

# --- GitLab forge tests ---

run_test "gitlab-valid-url" \
  "gitlab" \
  "https://gitlab.com/test-group/test-project/-/issues/42" \
  "Issue URL validated." \
  "false" \
  "CI_SERVER_HOST=gitlab.com"

run_test "gitlab-subgroup-url" \
  "gitlab" \
  "https://gitlab.com/top/sub/deep/project/-/issues/99" \
  "Issue URL validated." \
  "false" \
  "CI_SERVER_HOST=gitlab.com"

run_test "gitlab-malformed-url-fails" \
  "gitlab" \
  "https://gitlab.com/not-an-issue-url" \
  "does not match expected GitLab pattern" \
  "true" \
  "CI_SERVER_HOST=gitlab.com"

run_test "gitlab-non-allowlisted-host-fails" \
  "gitlab" \
  "https://evil.example/group/project/-/issues/1" \
  "does not match CI_SERVER_HOST" \
  "true" \
  "CI_SERVER_HOST=gitlab.com"

run_test "gitlab-internal-host-valid" \
  "gitlab" \
  "https://gitlab.cee.redhat.com/team/project/-/issues/5" \
  "Issue URL validated." \
  "false" \
  "CI_SERVER_HOST=gitlab.cee.redhat.com"

# --- GitLab dynamic host validation tests ---

# CI_SERVER_HOST trust source: accepts matching self-hosted instance.
run_test "gitlab-ci-server-host-accepts" \
  "gitlab" \
  "https://gitlab.example.com/group/project/-/issues/1" \
  "Issue URL validated." \
  "false" \
  "CI_SERVER_HOST=gitlab.example.com"

# Rejects host not matching CI_SERVER_HOST.
run_test "gitlab-untrusted-host-rejected" \
  "gitlab" \
  "https://evil.com/group/project/-/issues/1" \
  "does not match CI_SERVER_HOST" \
  "true" \
  "CI_SERVER_HOST=gitlab.example.com"

# Fails closed when CI_SERVER_HOST is not set.
run_test "gitlab-no-trust-source-fails-closed" \
  "gitlab" \
  "https://gitlab.com/group/project/-/issues/1" \
  "CI_SERVER_HOST is not set" \
  "true"

# --- Invalid forge ---

run_test "invalid-forge-fails" \
  "bitbucket" \
  "https://bitbucket.org/team/repo/issues/1" \
  "invalid FULLSEND_FORGE" \
  "true"

# --- Unset FULLSEND_FORGE ---

exit_code=0
env -u FULLSEND_FORGE ISSUE_URL="https://github.com/test-org/test-repo/issues/42" \
  bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout-unset-forge.log" 2>&1 || exit_code=$?

if [[ ${exit_code} -ne 0 ]]; then
  echo "PASS: unset-forge-fails (expected failure)"
else
  echo "FAIL: unset-forge-fails — expected failure but got success"
  FAILURES=$((FAILURES + 1))
fi

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
