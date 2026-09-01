#!/usr/bin/env bash
# pre-code-jira-test.sh — Test pre-code-jira.sh Jira-source pre-script.
#
# Validates URL parsing and error handling.  The script no longer fetches
# issue context (provider-backed API access replaced runner-side
# prefetch), so credential and context-file tests are omitted.
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

# --- Helpers ---

# build_mock creates mock binaries for forge_get_repo_dir / forge_append_path.
build_mock() {
  local mock_bin="${TMPDIR}/bin"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"

  # Mock gh (needed by code-ops.lib.sh for forge_get_repo_dir etc.)
  cat > "${mock_bin}/gh" <<'GHEOF'
#!/usr/bin/env bash
exit 0
GHEOF
  chmod +x "${mock_bin}/gh"

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
}

run_test() {
  local test_name="$1"
  local expect_exit="$2"
  local expected_stdout="$3"
  local extra_env="${4:-}"

  local mock_bin
  mock_bin="$(build_mock)"

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

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
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

# --- Test cases ---

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

# Script succeeds without JIRA_USER_EMAIL (no longer required by pre-script).
run_test "no-jira-email-still-succeeds" \
  0 \
  "Jira source:" \
  "JIRA_USER_EMAIL="

# Script succeeds without JIRA_TOKEN (no longer required by pre-script).
run_test "no-jira-token-still-succeeds" \
  0 \
  "Jira source:" \
  "JIRA_TOKEN="

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
