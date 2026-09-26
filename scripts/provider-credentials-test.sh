#!/usr/bin/env bash
# provider-credentials-test.sh — Verify OpenShell 0.1.x credential declarations.
#
# Token-bearing profiles must declare the env var their provider passes.
# Credential-less providers must omit the credentials: block (OpenShell
# 0.1.x creates a provider with no credentials; empty-map placeholder
# keys are rejected as undeclared).
#
# Run from the repo root: bash scripts/provider-credentials-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

assert_pass() {
  local test_name="$1"
  echo "PASS: ${test_name}"
}

assert_fail() {
  local test_name="$1"
  local detail="$2"
  echo "FAIL: ${test_name} — ${detail}"
  FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------------------
# Token-bearing profiles declare credentials immediately after category:
# ---------------------------------------------------------------------------
check_profile_credentials() {
  local rel="$1"
  local env_var="$2"
  local description="$3"
  local file="${REPO_ROOT}/${rel}"
  local test_name

  test_name="$(basename "${rel}" .yaml)-declares-${env_var}"
  if [ ! -f "${file}" ]; then
    assert_fail "${test_name}" "${rel} not found"
    return
  fi

  if ! grep -q '^credentials:' "${file}"; then
    assert_fail "${test_name}" "missing credentials: block"
    return
  fi

  # credentials: must sit directly after category: (issue #1512 shape).
  if ! grep -A1 '^category:' "${file}" | grep -q '^credentials:'; then
    assert_fail "${test_name}" "credentials: is not immediately after category:"
    return
  fi

  if ! grep -q 'name: api_token' "${file}"; then
    assert_fail "${test_name}" "missing name: api_token"
    return
  fi

  if ! grep -qF "description: ${description}" "${file}"; then
    assert_fail "${test_name}" "missing description: ${description}"
    return
  fi

  if ! grep -qF "env_vars: [${env_var}]" "${file}"; then
    assert_fail "${test_name}" "missing env_vars: [${env_var}]"
    return
  fi

  if ! grep -q 'required: true' "${file}"; then
    assert_fail "${test_name}" "missing required: true"
    return
  fi

  # Forge tokens are injected by the sandbox proxy; do not declare
  # OpenAI-style auth_style / header_name / refresh on these profiles.
  if grep -qE '^[[:space:]]*(auth_style|header_name|refresh):' "${file}"; then
    assert_fail "${test_name}" "must not declare auth_style, header_name, or refresh"
    return
  fi

  assert_pass "${test_name}"
}

check_profile_credentials "profiles/fullsend-github-ro.yaml" "GH_TOKEN" "GitHub token"
check_profile_credentials "profiles/fullsend-github-code.yaml" "GH_TOKEN" "GitHub token"
check_profile_credentials "profiles/fullsend-gitlab-ro.yaml" "GITLAB_TOKEN" "GitLab token"
check_profile_credentials "profiles/fullsend-gitlab-rw.yaml" "GITLAB_TOKEN" "GitLab token"
check_profile_credentials "profiles/fullsend-gitlab-code.yaml" "GITLAB_TOKEN" "GitLab token"
check_profile_credentials "profiles/fullsend-jira-ro.yaml" "JIRA_TOKEN" "Jira API token"

# ---------------------------------------------------------------------------
# Credential-less providers omit the credentials: block
# ---------------------------------------------------------------------------
check_provider_no_credentials() {
  local rel="$1"
  local file="${REPO_ROOT}/${rel}"
  local test_name

  test_name="$(basename "${rel}" .yaml)-no-credentials-block"
  if [ ! -f "${file}" ]; then
    assert_fail "${test_name}" "${rel} not found"
    return
  fi

  if grep -q '^credentials:' "${file}"; then
    assert_fail "${test_name}" "credentials: block must be omitted on OpenShell 0.1.x"
    return
  fi

  assert_pass "${test_name}"
}

check_provider_no_credentials "providers/vertex-ai.yaml"
check_provider_no_credentials "providers/gitleaks.yaml"
check_provider_no_credentials "providers/package-registries.yaml"
check_provider_no_credentials "providers/github-artifacts.yaml"

# Token-bearing providers still pass the real env var through.
check_provider_passes_token() {
  local rel="$1"
  local env_var="$2"
  local file="${REPO_ROOT}/${rel}"
  local test_name

  test_name="$(basename "${rel}" .yaml)-passes-${env_var}"
  if [ ! -f "${file}" ]; then
    assert_fail "${test_name}" "${rel} not found"
    return
  fi

  if ! grep -q '^credentials:' "${file}"; then
    assert_fail "${test_name}" "missing credentials: block"
    return
  fi

  if ! grep -qF "${env_var}: \"\${${env_var}}\"" "${file}"; then
    assert_fail "${test_name}" "missing ${env_var}: \"\${${env_var}}\""
    return
  fi

  assert_pass "${test_name}"
}

check_provider_passes_token "providers/github-ro.yaml" "GH_TOKEN"
check_provider_passes_token "providers/github-code.yaml" "GH_TOKEN"
check_provider_passes_token "providers/gitlab-ro.yaml" "GITLAB_TOKEN"
check_provider_passes_token "providers/gitlab-rw.yaml" "GITLAB_TOKEN"
check_provider_passes_token "providers/gitlab-code.yaml" "GITLAB_TOKEN"
check_provider_passes_token "providers/jira-ro.yaml" "JIRA_TOKEN"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All provider credential tests passed"
