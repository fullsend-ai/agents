#!/usr/bin/env bash
# harness-jira-test.sh — Verify Jira provider/profile configuration and
# credential boundary in triage and code harness files.
#
# Run from the repo root: bash scripts/harness-jira-test.sh

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
# Helper: extract a field from the Jira overlay in a harness YAML file.
# Uses python3+pyyaml to parse YAML safely.
#   $1 = harness YAML path
#   $2 = Python expression evaluated on the overlay dict 'ov'; must yield
#        an iterable whose items are printed one per line.
# ---------------------------------------------------------------------------
jira_overlay_field() {
  local harness_file="$1"
  local py_expr="$2"
  python3 -c "
import yaml
with open('${harness_file}') as f:
    doc = yaml.safe_load(f)
for ov in doc.get('overlays', []):
    if 'jira' in ov.get('when', ''):
        for item in (${py_expr}):
            print(item)
"
}

# ---------------------------------------------------------------------------
# Triage harness tests
# ---------------------------------------------------------------------------
TRIAGE_HARNESS="${REPO_ROOT}/harness/triage.yaml"

# Provider present
if jira_overlay_field "${TRIAGE_HARNESS}" "ov.get('providers', [])" | grep -qF "providers/jira-ro.yaml"; then
  assert_pass "triage-jira-provider-present"
else
  assert_fail "triage-jira-provider-present" "providers/jira-ro.yaml not in Jira overlay"
fi

# Profile present
if jira_overlay_field "${TRIAGE_HARNESS}" "ov.get('openshell', {}).get('profiles', [])" | grep -qF "profiles/fullsend-jira-ro.yaml"; then
  assert_pass "triage-jira-profile-present"
else
  assert_fail "triage-jira-profile-present" "profiles/fullsend-jira-ro.yaml not in Jira overlay"
fi

# JIRA_TOKEN not in sandbox env
if jira_overlay_field "${TRIAGE_HARNESS}" "ov.get('env', {}).get('sandbox', {})" | grep -qF "JIRA_TOKEN"; then
  assert_fail "triage-jira-token-not-in-sandbox" "JIRA_TOKEN found in sandbox env"
else
  assert_pass "triage-jira-token-not-in-sandbox"
fi

# JIRA_TOKEN still in runner env (needed for post-script mutations)
if jira_overlay_field "${TRIAGE_HARNESS}" "ov.get('env', {}).get('runner', {})" | grep -qF "JIRA_TOKEN"; then
  assert_pass "triage-jira-token-in-runner"
else
  assert_fail "triage-jira-token-in-runner" "JIRA_TOKEN missing from runner env (needed for post-script)"
fi

# JIRA_USER_EMAIL in sandbox env (non-secret, needed for Basic auth)
if jira_overlay_field "${TRIAGE_HARNESS}" "ov.get('env', {}).get('sandbox', {})" | grep -qF "JIRA_USER_EMAIL"; then
  assert_pass "triage-jira-email-in-sandbox"
else
  assert_fail "triage-jira-email-in-sandbox" "JIRA_USER_EMAIL missing from sandbox env"
fi

# JIRA_BASE_URL in sandbox env (non-secret, needed for API URLs)
if jira_overlay_field "${TRIAGE_HARNESS}" "ov.get('env', {}).get('sandbox', {})" | grep -qF "JIRA_BASE_URL"; then
  assert_pass "triage-jira-base-url-in-sandbox"
else
  assert_fail "triage-jira-base-url-in-sandbox" "JIRA_BASE_URL missing from sandbox env"
fi

# env/jira/triage.env does not contain JIRA_TOKEN
TRIAGE_ENV="${REPO_ROOT}/env/jira/triage.env"
if [ -f "${TRIAGE_ENV}" ]; then
  if grep -qF "JIRA_TOKEN" "${TRIAGE_ENV}"; then
    assert_fail "triage-env-file-no-token" "JIRA_TOKEN found in ${TRIAGE_ENV}"
  else
    assert_pass "triage-env-file-no-token"
  fi
else
  assert_fail "triage-env-file-no-token" "${TRIAGE_ENV} not found"
fi

# ---------------------------------------------------------------------------
# Code harness tests
# ---------------------------------------------------------------------------
CODE_HARNESS="${REPO_ROOT}/harness/code.yaml"

# Provider present
if jira_overlay_field "${CODE_HARNESS}" "ov.get('providers', [])" | grep -qF "providers/jira-ro.yaml"; then
  assert_pass "code-jira-provider-present"
else
  assert_fail "code-jira-provider-present" "providers/jira-ro.yaml not in Jira overlay"
fi

# Profile present
if jira_overlay_field "${CODE_HARNESS}" "ov.get('openshell', {}).get('profiles', [])" | grep -qF "profiles/fullsend-jira-ro.yaml"; then
  assert_pass "code-jira-profile-present"
else
  assert_fail "code-jira-profile-present" "profiles/fullsend-jira-ro.yaml not in Jira overlay"
fi

# JIRA_TOKEN not in sandbox env
if jira_overlay_field "${CODE_HARNESS}" "ov.get('env', {}).get('sandbox', {})" | grep -qF "JIRA_TOKEN"; then
  assert_fail "code-jira-token-not-in-sandbox" "JIRA_TOKEN found in sandbox env"
else
  assert_pass "code-jira-token-not-in-sandbox"
fi

# JIRA_TOKEN not in runner env (code agent runner doesn't need Jira creds)
if jira_overlay_field "${CODE_HARNESS}" "ov.get('env', {}).get('runner', {})" | grep -qF "JIRA_TOKEN"; then
  assert_fail "code-jira-token-not-in-runner" "JIRA_TOKEN found in runner env (no longer needed)"
else
  assert_pass "code-jira-token-not-in-runner"
fi

# JIRA_USER_EMAIL in sandbox env (non-secret, needed for Basic auth)
if jira_overlay_field "${CODE_HARNESS}" "ov.get('env', {}).get('sandbox', {})" | grep -qF "JIRA_USER_EMAIL"; then
  assert_pass "code-jira-email-in-sandbox"
else
  assert_fail "code-jira-email-in-sandbox" "JIRA_USER_EMAIL missing from sandbox env"
fi

# JIRA_BASE_URL in sandbox env (non-secret, needed for API URLs)
if jira_overlay_field "${CODE_HARNESS}" "ov.get('env', {}).get('sandbox', {})" | grep -qF "JIRA_BASE_URL"; then
  assert_pass "code-jira-base-url-in-sandbox"
else
  assert_fail "code-jira-base-url-in-sandbox" "JIRA_BASE_URL missing from sandbox env"
fi

# No .issue-context.json host_file (prefetch removed)
if jira_overlay_field "${CODE_HARNESS}" "[hf.get('dest', '') for hf in ov.get('host_files', [])]" | grep -qF ".issue-context.json"; then
  assert_fail "code-no-issue-context-host-file" ".issue-context.json still in host_files"
else
  assert_pass "code-no-issue-context-host-file"
fi

# JIRA_ISSUE_CONTEXT_FILE not in runner env (prefetch removed)
if jira_overlay_field "${CODE_HARNESS}" "ov.get('env', {}).get('runner', {})" | grep -qF "JIRA_ISSUE_CONTEXT_FILE"; then
  assert_fail "code-no-issue-context-file-env" "JIRA_ISSUE_CONTEXT_FILE still in runner env"
else
  assert_pass "code-no-issue-context-file-env"
fi

# ---------------------------------------------------------------------------
# Provider and profile file existence
# ---------------------------------------------------------------------------
if [ -f "${REPO_ROOT}/providers/jira-ro.yaml" ]; then
  assert_pass "provider-file-exists"
else
  assert_fail "provider-file-exists" "providers/jira-ro.yaml not found"
fi

if [ -f "${REPO_ROOT}/profiles/fullsend-jira-ro.yaml" ]; then
  assert_pass "profile-file-exists"
else
  assert_fail "profile-file-exists" "profiles/fullsend-jira-ro.yaml not found"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All harness Jira tests passed"
