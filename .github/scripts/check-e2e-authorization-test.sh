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
MOCK_ROLES_DIR="${TMPDIR}/roles"
PR_JSON="${TMPDIR}/pr.json"
EVENTS_JSON="${TMPDIR}/events.json"

mkdir -p "${MOCK_BIN}" "${MOCK_ROLES_DIR}"

set_role() {
  local login="$1"
  local role="$2"
  echo "${role}" > "${MOCK_ROLES_DIR}/${login}"
}

write_pr() {
  local assoc="${1:-CONTRIBUTOR}"
  local labels_json="${2:-[]}"
  local updated_at="${3:-2026-01-01T00:00:00Z}"
  local login="${4:-some-author}"
  jq -n --arg assoc "${assoc}" --argjson labels "${labels_json}" --arg updated_at "${updated_at}" --arg login "${login}" \
    '{author_association: $assoc, labels: $labels, updated_at: $updated_at, user: {login: $login}}' > "${PR_JSON}"
}

write_events() {
  local events_json="$1"
  echo "${events_json}" > "${EVENTS_JSON}"
}

setup_mock_gh() {
  cat > "${MOCK_BIN}/gh" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\${MOCK_FAIL_PULLS:-false}" == "true" ]] && [[ "\$*" == *"/pulls/"* ]]; then
  echo "mock-gh: simulated pulls failure" >&2
  exit 1
fi
if [[ "\${MOCK_FAIL_PERM:-false}" == "true" ]] && [[ "\$*" == *"/collaborators/"* ]]; then
  echo "mock-gh: simulated permission failure" >&2
  exit 1
fi

case "\$*" in
  *"/collaborators/"*"/permission"*)
    login="\$*"
    login="\${login#*/collaborators/}"
    login="\${login%%/permission*}"
    if [[ -f "${MOCK_ROLES_DIR}/\${login}" ]]; then
      role=\$(cat "${MOCK_ROLES_DIR}/\${login}")
    else
      role="read"
    fi
    echo "{\"role_name\": \"\${role}\"}"
    ;;
  *"/issues/"*"/events"*)
    if [[ -f "${EVENTS_JSON}" ]]; then
      cat "${EVENTS_JSON}"
    else
      echo '[]'
    fi
    ;;
  *"/pulls/"*)
    if [[ -f "${PR_JSON}" ]]; then
      cat "${PR_JSON}"
    else
      echo '{"author_association": "CONTRIBUTOR", "labels": [], "updated_at": "2026-01-01T00:00:00Z", "user": {"login": "some-author"}}'
    fi
    ;;
  *DELETE*)
    exit 0
    ;;
  *)
    echo "mock-gh: unhandled call: \$*" >&2
    exit 1
    ;;
esac
MOCKEOF
  chmod +x "${MOCK_BIN}/gh"
}

run_auth() {
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
  local expected_reason="${3:-unauthorized}"
  if echo "${output}" | grep -q "authorized=false" && echo "${output}" | grep -q "reason=${expected_reason}"; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected authorized=false reason=${expected_reason}, got: ${output}"
    FAILURES=$((FAILURES + 1))
  fi
}

setup_mock_gh

# --- Trusted bot tests ---
export PR_AUTHOR_ASSOCIATION="CONTRIBUTOR"
export PR_AUTHOR_LOGIN="fullsend-ai-coder[bot]"
output=$(run_auth 1 "test-org/test-repo")
assert_authorized "trusted bot fullsend-ai-coder[bot] is authorized" "${output}"

# Unknown bot is not trusted
export PR_AUTHOR_LOGIN="some-other-bot[bot]"
output=$(run_auth 1 "test-org/test-repo")
assert_unauthorized "unknown bot is not trusted" "${output}"

# --- Author permission tests (trust based on collaborator API, not author_association) ---
set_role "author-write" "write"
export PR_AUTHOR_ASSOCIATION="MEMBER"
export PR_AUTHOR_LOGIN="author-write"
output=$(run_auth 1 "test-org/test-repo")
assert_authorized "author with write permission is authorized" "${output}"

set_role "author-maintain" "maintain"
export PR_AUTHOR_ASSOCIATION="MEMBER"
export PR_AUTHOR_LOGIN="author-maintain"
output=$(run_auth 1 "test-org/test-repo")
assert_authorized "author with maintain permission is authorized" "${output}"

set_role "author-admin" "admin"
export PR_AUTHOR_ASSOCIATION="MEMBER"
export PR_AUTHOR_LOGIN="author-admin"
output=$(run_auth 1 "test-org/test-repo")
assert_authorized "author with admin permission is authorized" "${output}"

set_role "author-triage" "triage"
export PR_AUTHOR_ASSOCIATION="MEMBER"
export PR_AUTHOR_LOGIN="author-triage"
output=$(run_auth 1 "test-org/test-repo")
assert_unauthorized "author with triage permission denied (even if MEMBER)" "${output}"

set_role "author-read" "read"
export PR_AUTHOR_ASSOCIATION="COLLABORATOR"
export PR_AUTHOR_LOGIN="author-read"
output=$(run_auth 1 "test-org/test-repo")
assert_unauthorized "author with read permission denied (even if COLLABORATOR)" "${output}"

# External contributor without permissions denied
export PR_AUTHOR_ASSOCIATION="CONTRIBUTOR"
export PR_AUTHOR_LOGIN="random-contributor"
output=$(run_auth 1 "test-org/test-repo")
assert_unauthorized "CONTRIBUTOR without bot login is unauthorized" "${output}"

# --- ok-to-test and synchronize tests ---
# Synchronize with existing ok-to-test label is invalidated
write_pr "CONTRIBUTOR" '[{"name":"ok-to-test"}]' "2026-01-01T10:00:00Z" "random-contributor"
write_events '[{"event":"labeled","label":{"name":"ok-to-test"},"created_at":"2026-01-01T11:00:00Z","actor":{"login":"maintainer"}}]'
set_role "maintainer" "write"
export EVENT_ACTION="synchronize"
export CHECK_E2E_AUTH_DRY_RUN="true"
output=$(run_auth 1 "test-org/test-repo")
assert_unauthorized "synchronize with existing ok-to-test invalidates approval" "${output}" "stale_ok_to_test"
unset EVENT_ACTION CHECK_E2E_AUTH_DRY_RUN

# Fresh ok-to-test label by write maintainer on labeled event is authorized
export EVENT_ACTION="labeled"
export LABEL_ACTOR_LOGIN="maintainer"
output=$(run_auth 1 "test-org/test-repo")
assert_authorized "ok-to-test label by write maintainer is authorized" "${output}"

# ok-to-test label applied by triage user is denied and untrusted_labeler
set_role "triager" "triage"
export LABEL_ACTOR_LOGIN="triager"
export CHECK_E2E_AUTH_DRY_RUN="true"
output=$(run_auth 1 "test-org/test-repo")
assert_unauthorized "ok-to-test by triage user is denied as untrusted_labeler" "${output}" "untrusted_labeler"
unset EVENT_ACTION LABEL_ACTOR_LOGIN CHECK_E2E_AUTH_DRY_RUN

# --- Warning annotations & error handling ---
write_pr "CONTRIBUTOR" '[]'
export PR_AUTHOR_LOGIN="random-contributor"
output=$(run_auth 1 "test-org/test-repo")
if echo "${output}" | grep -q '::warning::'; then
  echo "PASS: denial emits ::warning:: annotation"
else
  echo "FAIL: denial emits ::warning:: annotation — got: ${output}"
  FAILURES=$((FAILURES + 1))
fi

# API failure (ERR trap)
export MOCK_FAIL_PULLS="true"
unset PR_AUTHOR_ASSOCIATION PR_AUTHOR_LOGIN
write_pr "NONE" '[]'
output=$(run_auth 1 "test-org/test-repo")
assert_unauthorized "API failure (ERR trap) is unauthorized" "${output}" "error"
if echo "${output}" | grep -q '::warning::'; then
  echo "PASS: API failure emits ::warning:: annotation"
else
  echo "FAIL: API failure emits ::warning:: annotation — got: ${output}"
  FAILURES=$((FAILURES + 1))
fi
unset MOCK_FAIL_PULLS

# Authorized run does not emit warning
export PR_AUTHOR_LOGIN="author-write"
export PR_AUTHOR_ASSOCIATION="MEMBER"
output=$(run_auth 1 "test-org/test-repo")
if echo "${output}" | grep -q '::warning::'; then
  echo "FAIL: authorized run should not emit ::warning:: — got: ${output}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: authorized run does not emit ::warning::"
fi

# --- Summary ---
echo ""
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
else
  echo "All tests passed"
fi
