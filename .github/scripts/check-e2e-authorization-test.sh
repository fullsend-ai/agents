#!/usr/bin/env bash
# check-e2e-authorization-test.sh — Tests for check-e2e-authorization.sh
#
# Uses a mock gh command to avoid hitting GitHub.
# Run from the repo root: bash .github/scripts/check-e2e-authorization-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_SCRIPT="${SCRIPT_DIR}/check-e2e-authorization.sh"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"

# Mock gh: default behavior returns CONTRIBUTOR association and no ok-to-test label.
setup_mock_gh() {
  cat > "${MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
# Default: PR endpoint returns CONTRIBUTOR with no ok-to-test label
if [[ "$1" == "api" ]] && [[ "$2" == *"/pulls/"* ]] && [[ "$2" != *"/files"* ]]; then
  echo '{"author_association": "CONTRIBUTOR", "labels": [], "updated_at": "2026-01-01T00:00:00Z"}'
  exit 0
fi
# Collaborator permission endpoint: default to read (not write)
if [[ "$1" == "api" ]] && [[ "$2" == *"/collaborators/"*"/permission"* ]]; then
  echo '{"role_name": "read"}'
  exit 0
fi
echo "mock-gh: unhandled call: $*" >&2
exit 1
MOCKEOF
  chmod +x "${MOCK_BIN}/gh"
}

run_auth() {
  # Run the script, capture stdout, suppress stderr
  local output
  output=$(
    export PATH="${MOCK_BIN}:${PATH}"
    export GH_TOKEN="fake-token"
    export GITHUB_OUTPUT="${TMPDIR}/github-output"
    : > "${GITHUB_OUTPUT}"
    bash "${AUTH_SCRIPT}" "$@" 2>/dev/null
  )
  echo "${output}"
}

get_github_output() {
  cat "${TMPDIR}/github-output"
}

assert_authorized() {
  local test_name="$1"
  local output="$2"
  if echo "${output}" | grep -q "authorized=true"; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected authorized=true, got: ${output}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_unauthorized() {
  local test_name="$1"
  local output="$2"
  if echo "${output}" | grep -q "authorized=false"; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected authorized=false, got: ${output}"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Tests ---

# Test: trusted bot (fullsend-ai-coder[bot]) is authorized
setup_mock_gh
export PR_AUTHOR_ASSOCIATION="CONTRIBUTOR"
export PR_AUTHOR_LOGIN="fullsend-ai-coder[bot]"
output=$(run_auth 1 "test-org/test-repo")
assert_authorized "trusted bot fullsend-ai-coder[bot] is authorized" "${output}"

# Test: MEMBER association is authorized
setup_mock_gh
export PR_AUTHOR_ASSOCIATION="MEMBER"
export PR_AUTHOR_LOGIN="some-human"
output=$(run_auth 1 "test-org/test-repo")
assert_authorized "MEMBER association is authorized" "${output}"

# Test: OWNER association is authorized
setup_mock_gh
export PR_AUTHOR_ASSOCIATION="OWNER"
export PR_AUTHOR_LOGIN="some-human"
output=$(run_auth 1 "test-org/test-repo")
assert_authorized "OWNER association is authorized" "${output}"

# Test: COLLABORATOR association is authorized
setup_mock_gh
export PR_AUTHOR_ASSOCIATION="COLLABORATOR"
export PR_AUTHOR_LOGIN="some-human"
output=$(run_auth 1 "test-org/test-repo")
assert_authorized "COLLABORATOR association is authorized" "${output}"

# Test: CONTRIBUTOR association without bot login is unauthorized
setup_mock_gh
export PR_AUTHOR_ASSOCIATION="CONTRIBUTOR"
export PR_AUTHOR_LOGIN="random-contributor"
output=$(run_auth 1 "test-org/test-repo")
assert_unauthorized "CONTRIBUTOR without bot login is unauthorized" "${output}"

# Test: unknown bot is not trusted
setup_mock_gh
export PR_AUTHOR_ASSOCIATION="CONTRIBUTOR"
export PR_AUTHOR_LOGIN="some-other-bot[bot]"
output=$(run_auth 1 "test-org/test-repo")
assert_unauthorized "unknown bot is not trusted" "${output}"

# --- Summary ---
echo ""
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
else
  echo "All tests passed"
fi
