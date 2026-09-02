#!/usr/bin/env bash
# sandbox-credential-boundary-test.sh — Verify denylisted credentials
# never appear in sandbox expansion paths across all harness files.
#
# The "sandbox expansion denylist" prevents credentials from leaking
# into the sandbox through two paths:
#
#   1. env.sandbox values — catches both direct keys (JIRA_TOKEN: "...")
#      and aliases (LEAK: "${JIRA_TOKEN}") that would expand the real
#      credential into the sandbox under a different name.
#
#   2. host_files with expand: true — catches expanded env files that
#      reference a denylisted variable (e.g. export FOO="${JIRA_TOKEN}").
#
# This is defense-in-depth: even if a child overlay or harness
# regression re-introduces a denylisted credential, this test catches
# it before merge.
#
# Run from the repo root: bash scripts/sandbox-credential-boundary-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

# ---------------------------------------------------------------------------
# Sandbox expansion denylist
# ---------------------------------------------------------------------------
# Credentials that must never be expanded into any sandbox environment.
# Add new entries here when onboarding provider-backed credentials.
DENYLIST=(
  JIRA_TOKEN
  OPENAI_API_KEY
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
assert_pass() { echo "PASS: $1"; }
assert_fail() {
  local test_name="$1" detail="$2"
  echo "FAIL: ${test_name} — ${detail}"
  FAILURES=$((FAILURES + 1))
}

# check_env_sandbox — scan env.sandbox values (top-level + overlays) for
# a denylisted variable reference.  Catches both KEY matches and VALUE
# expansion patterns like ${VAR}.
check_env_sandbox() {
  local harness_file="$1" denied_var="$2"
  local pattern="\${${denied_var}}"
  yq -r '[.env.sandbox // {}, .overlays[]?.env.sandbox // {}] | .[] | to_entries[] | [.key, .value] | @tsv' "${harness_file}" |
    while IFS=$'\t' read -r key value; do
      if [[ "${key}" == "${denied_var}" || "${value}" == *"${pattern}"* ]]; then
        echo "${key}=${value}"
      fi
    done
}

# check_host_files — scan host_files with expand: true for denylisted
# variable references in their source files.
check_host_files() {
  local harness_file="$1" denied_var="$2"
  local src src_path
  while IFS= read -r src; do
    [[ "${src}" == *'$'* ]] && continue
    src_path="${REPO_ROOT}/${src}"
    if [[ -f "${src_path}" ]] && grep -qF "${denied_var}" "${src_path}"; then
      echo "${src}"
    fi
  done < <(yq -r '[.host_files // [], .overlays[]?.host_files // []] | flatten | .[] | select(.expand == true) | .src' "${harness_file}")
}

# ---------------------------------------------------------------------------
# Discover harness files
# ---------------------------------------------------------------------------
HARNESS_DIR="${REPO_ROOT}/harness"
HARNESS_FILES=()
for f in "${HARNESS_DIR}"/*.yaml; do
  [[ -f "$f" ]] && HARNESS_FILES+=("$f")
done

if [[ ${#HARNESS_FILES[@]} -eq 0 ]]; then
  echo "ERROR: no harness YAML files found in ${HARNESS_DIR}"
  exit 1
fi

echo "Scanning ${#HARNESS_FILES[@]} harness file(s) against ${#DENYLIST[@]} denylisted credential(s)"
echo ""

# ---------------------------------------------------------------------------
# Test: env.sandbox must not reference denylisted vars
# ---------------------------------------------------------------------------
for harness in "${HARNESS_FILES[@]}"; do
  harness_name="$(basename "$harness" .yaml)"
  for denied_var in "${DENYLIST[@]}"; do
    test_name="${harness_name}-env-sandbox-no-${denied_var}"
    matches="$(check_env_sandbox "$harness" "$denied_var")"
    if [[ -n "$matches" ]]; then
      assert_fail "$test_name" "denylisted credential reference: ${matches}"
    else
      assert_pass "$test_name"
    fi
  done
done

# ---------------------------------------------------------------------------
# Test: expanded host_files must not reference denylisted vars
# ---------------------------------------------------------------------------
for harness in "${HARNESS_FILES[@]}"; do
  harness_name="$(basename "$harness" .yaml)"
  for denied_var in "${DENYLIST[@]}"; do
    test_name="${harness_name}-host-files-no-${denied_var}"
    matches="$(check_host_files "$harness" "$denied_var")"
    if [[ -n "$matches" ]]; then
      assert_fail "$test_name" "denylisted credential in expanded host file: ${matches}"
    else
      assert_pass "$test_name"
    fi
  done
done

# ---------------------------------------------------------------------------
# Test: Jira skill files carry the opaque placeholder through Basic auth
# ---------------------------------------------------------------------------
# This is the positive complement to the sandbox env denylist above:
# the real JIRA_TOKEN never enters sandbox config (env.sandbox, env files),
# but sandbox curl commands must still carry the provider-supplied opaque
# placeholder via --user for Basic auth.
JIRA_SKILL_FILES=(
  "${REPO_ROOT}/skills/jira-forge/SKILL.md"
  "${REPO_ROOT}/skills/issue-labels/jira/SKILL.md"
  "${REPO_ROOT}/skills/jira-components/SKILL.md"
  "${REPO_ROOT}/skills/code-implementation/SKILL.md"
)

for skill_file in "${JIRA_SKILL_FILES[@]}"; do
  skill_name="$(basename "$(dirname "${skill_file}")")"
  test_name="skill-${skill_name}-uses-basic-auth-placeholder"

  if [ ! -f "${skill_file}" ]; then
    assert_fail "${test_name}" "${skill_file} not found"
    continue
  fi

  if grep -qF -- '--user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}"' "${skill_file}"; then
    assert_pass "${test_name}"
  else
    assert_fail "${test_name}" "missing --user Basic auth with opaque JIRA_TOKEN placeholder"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All sandbox credential boundary tests passed"
