#!/usr/bin/env bash
# pre-code-jira-test.sh — Test pre-code-jira.sh Jira-source pre-script.
#
# Validates URL parsing, issue context fetching, and error handling.
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

# build_mock creates a mock fullsend binary that returns preconfigured output.
# Also creates a mock gh binary for forge_get_repo_dir / forge_append_path.
build_mock() {
  local issue_json="$1"
  local fullsend_exit="${2:-0}"
  local mock_bin="${TMPDIR}/bin"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"

  # Write the expected issue JSON to a file for the mock to return.
  printf '%s' "${issue_json}" > "${TMPDIR}/issue-output.json"

  # Mock fullsend CLI
  cat > "${mock_bin}/fullsend" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$1" == "issues" && "\$2" == "get" ]]; then
  cat "${TMPDIR}/issue-output.json"
  exit ${fullsend_exit}
fi
exit 1
MOCKEOF
  chmod +x "${mock_bin}/fullsend"

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
  local issue_json="$2"
  local expect_exit="$3"
  local expected_stdout="$4"
  local extra_env="${5:-}"
  local fullsend_exit="${6:-0}"

  local mock_bin
  mock_bin="$(build_mock "${issue_json}" "${fullsend_exit}")"

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

# --- Test data ---
VALID_ISSUE_JSON='{"title":"Fix the widget","body":"The widget is broken","labels":["bug"],"comments":[]}'

# --- Test cases ---

# Valid Jira→GitHub composition succeeds and writes context file.
run_test "valid-jira-github-succeeds" \
  "${VALID_ISSUE_JSON}" \
  0 \
  "Jira issue context written to"

# Valid Jira→GitLab composition also works.
run_test "valid-jira-gitlab-succeeds" \
  "${VALID_ISSUE_JSON}" \
  0 \
  "Jira issue context written to" \
  "FULLSEND_FORGE=gitlab"

# Invalid Jira URL pattern is rejected.
run_test "invalid-jira-url-rejected" \
  "${VALID_ISSUE_JSON}" \
  1 \
  "does not match expected Jira pattern" \
  "ISSUE_URL=https://github.com/org/repo/issues/1"

# Non-atlassian.net host is rejected.
run_test "non-atlassian-host-rejected" \
  "${VALID_ISSUE_JSON}" \
  1 \
  "not in the allowed host list" \
  "ISSUE_URL=https://evil.example.com/browse/PROJ-42"

# JIRA_BASE_URL mismatch is rejected.
run_test "base-url-mismatch-rejected" \
  "${VALID_ISSUE_JSON}" \
  1 \
  "does not match ISSUE_URL host" \
  "JIRA_BASE_URL=https://other.atlassian.net"

# JIRA_BASE_URL with trailing slash normalizes and matches.
run_test "base-url-trailing-slash-normalizes" \
  "${VALID_ISSUE_JSON}" \
  0 \
  "Jira issue context written to" \
  "JIRA_BASE_URL=https://acme.atlassian.net/"

# fullsend CLI failure is caught.
run_test "fullsend-cli-failure" \
  "" \
  1 \
  "Failed to fetch Jira issue" \
  "" \
  "1"

# fullsend CLI writes empty output — empty-file guard catches it.
# Uses a custom mock that succeeds (exit 0) but writes nothing.
run_test_empty_context() {
  local test_name="$1"
  local mock_bin="${TMPDIR}/bin"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"

  # Mock fullsend that succeeds but produces no output.
  cat > "${mock_bin}/fullsend" <<'EMPTYEOF'
#!/usr/bin/env bash
if [[ "$1" == "issues" && "$2" == "get" ]]; then
  # Write nothing — simulates an empty API response.
  exit 0
fi
exit 1
EMPTYEOF
  chmod +x "${mock_bin}/fullsend"

  # Reuse standard gh/git/python3 mocks.
  cat > "${mock_bin}/gh" <<'GHEOF'
#!/usr/bin/env bash
exit 0
GHEOF
  chmod +x "${mock_bin}/gh"
  cat > "${mock_bin}/git" <<'GITEOF'
#!/usr/bin/env bash
exit 1
GITEOF
  chmod +x "${mock_bin}/git"
  cat > "${mock_bin}/python3" <<'PYEOF'
#!/usr/bin/env bash
exit 1
PYEOF
  chmod +x "${mock_bin}/python3"

  local env_cmd=(env)
  while IFS= read -r kv; do
    [[ -n "${kv}" ]] && env_cmd+=("${kv}")
  done <<< "$(base_env "${mock_bin}")"

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 1 ]]; then
    echo "FAIL: ${test_name} — expected exit 1, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "Jira issue context is empty" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected 'Jira issue context is empty' in output"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_empty_context "empty-issue-context-rejected"

# Invalid JSON issue context is rejected.
run_test "invalid-json-rejected" \
  "not valid json" \
  1 \
  "not valid JSON"

# Missing JIRA_USER_EMAIL is rejected.
run_test "missing-jira-email-rejected" \
  "${VALID_ISSUE_JSON}" \
  1 \
  "JIRA_USER_EMAIL must be set" \
  "JIRA_USER_EMAIL="

# Missing JIRA_TOKEN is rejected.
run_test "missing-jira-token-rejected" \
  "${VALID_ISSUE_JSON}" \
  1 \
  "JIRA_TOKEN must be set" \
  "JIRA_TOKEN="

# Verifies the context file content is the fetched issue JSON.
run_test_context_file() {
  local test_name="$1"
  local issue_json="$2"

  local mock_bin
  mock_bin="$(build_mock "${issue_json}")"

  local env_cmd=(env)
  while IFS= read -r kv; do
    [[ -n "${kv}" ]] && env_cmd+=("${kv}")
  done <<< "$(base_env "${mock_bin}")"

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — script exited ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local context_file="/tmp/jira-issue-context.json"
  if [[ ! -f "${context_file}" ]]; then
    echo "FAIL: ${test_name} — context file not created at ${context_file}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! diff <(printf '%s' "${issue_json}") "${context_file}" > "${TMPDIR}/diff.log" 2>&1; then
    echo "FAIL: ${test_name} — context file content mismatch"
    cat "${TMPDIR}/diff.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_context_file "context-file-matches-fetched-json" \
  "${VALID_ISSUE_JSON}"

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
