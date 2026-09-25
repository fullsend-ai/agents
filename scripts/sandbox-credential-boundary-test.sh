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
  GH_TOKEN
  GITLAB_TOKEN
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

# check_env_sandbox — scan env.sandbox values (top-level, overlays, and
# forge blocks) for a denylisted variable reference.  Catches both KEY
# matches and VALUE expansion patterns like ${VAR}.
check_env_sandbox() {
  local harness_file="$1" denied_var="$2"
  local pattern="\${${denied_var}}"
  yq -r '[
      (.env.sandbox // {}),
      (.overlays[]? | .env.sandbox // {}),
      (.forge[]? | .env.sandbox // {})
    ] | .[] | to_entries[] | [.key, .value] | @tsv' "${harness_file}" |
    while IFS=$'\t' read -r key value; do
      if [[ "${key}" == "${denied_var}" || "${value}" == *"${pattern}"* ]]; then
        echo "${key}=${value}"
      fi
    done
}

# skill_rel_name — unique test-name slug from a skills/ path.
# skills/github-forge/SKILL.md        → github-forge
# skills/issue-labels/gitlab/SKILL.md → issue-labels-gitlab
skill_rel_name() {
  local skill_file="$1"
  local rel="${skill_file#"${REPO_ROOT}/skills/"}"
  rel="${rel%/SKILL.md}"
  echo "${rel//\//-}"
}

# check_host_files — scan host_files with expand: true (top-level,
# overlays, and forge blocks) for denylisted variable references in
# their source files.
check_host_files() {
  local harness_file="$1" denied_var="$2"
  local src src_path
  while IFS= read -r src; do
    [[ "${src}" == *'$'* ]] && continue
    src_path="${REPO_ROOT}/${src}"
    if [[ -f "${src_path}" ]] && grep -qF "${denied_var}" "${src_path}"; then
      echo "${src}"
    fi
  done < <(yq -r '[
      (.host_files // []),
      (.overlays[]? | .host_files // []),
      (.forge[]? | .host_files // [])
    ] | flatten | .[] | select(.expand == true) | .src' "${harness_file}")
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
# Test: GitHub skill files send GH_TOKEN through Authorization (via gh)
# ---------------------------------------------------------------------------
# Positive complement to the GH_TOKEN sandbox denylist: the real token never
# enters sandbox config, but sandbox GitHub API calls must still go through
# an OpenShell-rewritten Authorization header. The gh CLI reads GH_TOKEN from
# the environment and sends it as Authorization; OpenShell replaces the
# provider placeholder at the proxy boundary — the same header family as
# Jira Basic auth, which this script verifies above.
GITHUB_SKILL_FILES=(
  "${REPO_ROOT}/skills/github-forge/SKILL.md"
  "${REPO_ROOT}/skills/fix-review/github/SKILL.md"
)

for skill_file in "${GITHUB_SKILL_FILES[@]}"; do
  skill_name="$(skill_rel_name "${skill_file}")"
  test_name="skill-${skill_name}-uses-authorization-placeholder"

  if [ ! -f "${skill_file}" ]; then
    assert_fail "${test_name}" "${skill_file} not found"
    continue
  fi

  if grep -qF 'provides `GH_TOKEN` for authentication' "${skill_file}" &&
    grep -qE 'gh (issue|pr|api|run|label)' "${skill_file}"; then
    assert_pass "${test_name}"
  else
    assert_fail "${test_name}" "missing gh CLI auth via GH_TOKEN (Authorization-family path)"
  fi
done

# Canonical GitHub forge skill must name the Authorization rewrite path
# explicitly, matching the Jira skill's documented Basic-auth contract.
test_name="skill-github-forge-documents-authorization-rewrite"
github_forge="${REPO_ROOT}/skills/github-forge/SKILL.md"
if grep -qF 'Authorization' "${github_forge}" &&
  grep -qF 'OpenShell' "${github_forge}"; then
  assert_pass "${test_name}"
else
  assert_fail "${test_name}" "github-forge skill must document that gh sends Authorization for OpenShell rewrite"
fi

# ---------------------------------------------------------------------------
# Test: GitHub skill files must not send GH_TOKEN via an unverified header
# ---------------------------------------------------------------------------
# Regression guard against every GitHub skill file, matching GitLab's
# exhaustive no-private-token coverage below: gh sends GH_TOKEN via
# Authorization, so no skill should introduce a custom header carrying it.
# Flags GH_TOKEN on the same -H/--header line, on the line right after a
# -H/--header flag (continuation), and in curl --config `header = ...`
# lines, since none of those forms carry the token through Authorization.
GITHUB_TOKEN_HEADER_FILES=(
  "${REPO_ROOT}/skills/github-forge/SKILL.md"
  "${REPO_ROOT}/skills/fix-review/github/SKILL.md"
  "${REPO_ROOT}/skills/finding-agent-runs/github/SKILL.md"
  "${REPO_ROOT}/skills/issue-labels/github/SKILL.md"
  "${REPO_ROOT}/skills/pr-review/github/SKILL.md"
  "${REPO_ROOT}/skills/retro-analysis/github/SKILL.md"
)

for skill_file in "${GITHUB_TOKEN_HEADER_FILES[@]}"; do
  skill_name="$(skill_rel_name "${skill_file}")"
  test_name="skill-${skill_name}-no-unverified-token-header"

  if [ ! -f "${skill_file}" ]; then
    assert_fail "${test_name}" "${skill_file} not found"
    continue
  fi

  if grep -qF 'PRIVATE-TOKEN' "${skill_file}" ||
    grep -A 1 -E -- '(-H|--header)' "${skill_file}" | grep -qF 'GH_TOKEN' ||
    grep -E -- 'header[[:space:]]*=' "${skill_file}" | grep -qF 'GH_TOKEN'; then
    assert_fail "${test_name}" "GH_TOKEN must not be passed via a custom header; gh sends Authorization"
  else
    assert_pass "${test_name}"
  fi
done

# ---------------------------------------------------------------------------
# Test: GitLab skill files carry GITLAB_TOKEN through Authorization: Bearer
# ---------------------------------------------------------------------------
# PRIVATE-TOKEN has no established OpenShell rewrite precedent in this repo
# (unlike Authorization, which Jira Basic auth and GitHub gh both use).
# GitLab's REST API accepts Authorization: Bearer for personal/project access
# tokens, so sandbox skills must use that header. Runner-side pre/post
# scripts keep PRIVATE-TOKEN: they hold the real token via env.runner and
# are not proxied through OpenShell.
GITLAB_SKILL_FILES=(
  "${REPO_ROOT}/skills/gitlab-forge/SKILL.md"
  "${REPO_ROOT}/skills/issue-labels/gitlab/SKILL.md"
  "${REPO_ROOT}/skills/pr-review/gitlab/SKILL.md"
  "${REPO_ROOT}/skills/finding-agent-runs/gitlab/SKILL.md"
  "${REPO_ROOT}/skills/fix-review/gitlab/SKILL.md"
  "${REPO_ROOT}/skills/retro-analysis/gitlab/SKILL.md"
)

for skill_file in "${GITLAB_SKILL_FILES[@]}"; do
  skill_name="$(skill_rel_name "${skill_file}")"
  test_name="skill-${skill_name}-uses-bearer-auth-placeholder"

  if [ ! -f "${skill_file}" ]; then
    assert_fail "${test_name}" "${skill_file} not found"
    continue
  fi

  if grep -qF 'Authorization: Bearer ${GITLAB_TOKEN}' "${skill_file}" ||
    grep -qF 'Authorization: Bearer %s' "${skill_file}"; then
    assert_pass "${test_name}"
  else
    assert_fail "${test_name}" "missing Authorization: Bearer with GITLAB_TOKEN placeholder"
  fi

  test_name="skill-${skill_name}-no-private-token-header"
  if grep -qF 'PRIVATE-TOKEN' "${skill_file}"; then
    assert_fail "${test_name}" "PRIVATE-TOKEN has no established OpenShell rewrite precedent; use Authorization: Bearer"
  else
    assert_pass "${test_name}"
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
