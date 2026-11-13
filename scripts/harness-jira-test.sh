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
# Uses yq, which the script-test workflow installs.
#   $1 = harness YAML path
#   $2 = yq expression evaluated on the Jira overlay.
# ---------------------------------------------------------------------------
jira_overlay_field() {
  local harness_file="$1"
  local yq_expr="$2"
  yq -r ".overlays[] | select(.when | contains(\"jira\")) | ${yq_expr}" "${harness_file}"
}

# Search an overlay field's output for a literal string without a pipe.
# `jira_overlay_field ... | grep -qF` races: grep exits at the first match, yq
# takes SIGPIPE while it is still writing, and `set -o pipefail` turns that
# into exit 141 — a passing assertion reported as a failure. The race only
# shows when the match is early in multi-line output, which is why the
# negative and single-line checks never flaked.
jira_overlay_has() {
  local out
  out="$(jira_overlay_field "$1" "$2")"
  grep -qF "$3" <<< "${out}"
}

# ---------------------------------------------------------------------------
# Triage harness tests
# ---------------------------------------------------------------------------
TRIAGE_HARNESS="${REPO_ROOT}/harness/triage.yaml"

# Provider present
if jira_overlay_has "${TRIAGE_HARNESS}" ".providers[]" "providers/jira-ro.yaml"; then
  assert_pass "triage-jira-provider-present"
else
  assert_fail "triage-jira-provider-present" "providers/jira-ro.yaml not in Jira overlay"
fi

# Profile present
if jira_overlay_has "${TRIAGE_HARNESS}" ".openshell.profiles[]" "profiles/fullsend-jira-ro.yaml"; then
  assert_pass "triage-jira-profile-present"
else
  assert_fail "triage-jira-profile-present" "profiles/fullsend-jira-ro.yaml not in Jira overlay"
fi

# JIRA_TOKEN not in sandbox env
if jira_overlay_has "${TRIAGE_HARNESS}" "(.env.sandbox // {}) | keys | .[]" "JIRA_TOKEN"; then
  assert_fail "triage-jira-token-not-in-sandbox" "JIRA_TOKEN found in sandbox env"
else
  assert_pass "triage-jira-token-not-in-sandbox"
fi

# JIRA_TOKEN still in runner env (needed for post-script mutations)
if jira_overlay_has "${TRIAGE_HARNESS}" "(.env.runner // {}) | keys | .[]" "JIRA_TOKEN"; then
  assert_pass "triage-jira-token-in-runner"
else
  assert_fail "triage-jira-token-in-runner" "JIRA_TOKEN missing from runner env (needed for post-script)"
fi

# JIRA_USER_EMAIL reaches the sandbox through the expanded host file, not
# env.sandbox: it is optional (a service account has none), and an unset
# ${VAR} in env.sandbox fails the run (#1900).
if grep -qF 'export JIRA_USER_EMAIL=' "${REPO_ROOT}/env/jira/triage.env" \
  && ! jira_overlay_has "${TRIAGE_HARNESS}" "(.env.sandbox // {}) | keys | .[]" "JIRA_USER_EMAIL"; then
  assert_pass "triage-jira-email-in-sandbox-host-file"
else
  assert_fail "triage-jira-email-in-sandbox-host-file" "JIRA_USER_EMAIL must come from env/jira/triage.env, not env.sandbox"
fi

# Host-side credentials come from the FULLSEND_JIRA_* repository secrets
# (fullsend#9079), and the fullsend CLI gets the .fullsend directory.
check_runner_mapping() {
  local harness_file="$1" prefix="$2" key="$3" want="$4"
  local got
  got="$(jira_overlay_field "${harness_file}" ".env.runner.${key} // \"\"")"
  if [[ "${got}" == "${want}" ]]; then
    assert_pass "${prefix}-runner-${key}-mapping"
  else
    assert_fail "${prefix}-runner-${key}-mapping" "env.runner.${key} is '${got}', want '${want}'"
  fi
}
check_runner_mapping "${TRIAGE_HARNESS}" triage JIRA_TOKEN '${FULLSEND_JIRA_TOKEN}'
check_runner_mapping "${TRIAGE_HARNESS}" triage JIRA_USER_EMAIL '${FULLSEND_JIRA_EMAIL}'
check_runner_mapping "${TRIAGE_HARNESS}" triage FULLSEND_DIR '${FULLSEND_DIR}'

# fullsend refuses FULLSEND_JIRA_* at sandbox-bound sites, so no sandbox
# env, Jira host file, or provider may reference them.
for f in "${TRIAGE_HARNESS}" "${REPO_ROOT}/harness/code.yaml"; do
  name="$(basename "${f}" .yaml)"
  if jira_overlay_field "${f}" "(.env.sandbox // {}) | to_entries | .[] | .key + \"=\" + .value" | grep -qF 'FULLSEND_JIRA_'; then
    assert_fail "${name}-no-fullsend-jira-in-sandbox" "FULLSEND_JIRA_* referenced in env.sandbox"
  else
    assert_pass "${name}-no-fullsend-jira-in-sandbox"
  fi
done
if grep -hv '^[[:space:]]*#' "${REPO_ROOT}"/env/jira/*.env "${REPO_ROOT}/providers/jira-ro.yaml" | grep -qF 'FULLSEND_JIRA_'; then
  assert_fail "no-fullsend-jira-in-host-files-or-provider" "FULLSEND_JIRA_* referenced in a Jira host file or the provider"
else
  assert_pass "no-fullsend-jira-in-host-files-or-provider"
fi

# JIRA_BASE_URL in sandbox env (non-secret, needed for API URLs)
if jira_overlay_has "${TRIAGE_HARNESS}" "(.env.sandbox // {}) | keys | .[]" "JIRA_BASE_URL"; then
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

# CODE_ALLOWED_TARGET_BRANCHES is optional. Mapping it through env.runner
# makes fullsend reject runs where the host does not define it, before the
# post-script can safely fall back to the repository default branch.
if yq -e '.env.runner | has("CODE_ALLOWED_TARGET_BRANCHES")' "${CODE_HARNESS}" >/dev/null; then
  assert_fail "code-optional-target-branches-not-required" "CODE_ALLOWED_TARGET_BRANCHES must not be mapped through env.runner"
else
  assert_pass "code-optional-target-branches-not-required"
fi

# when: must guard event.source so non-Jira runs skip instead of CEL-erroring
code_jira_when="$(jira_overlay_field "${CODE_HARNESS}" ".when")"
if echo "${code_jira_when}" | grep -qF 'has(event.source)'; then
  assert_pass "code-jira-when-guards-source"
else
  assert_fail "code-jira-when-guards-source" \
    "when expression lacks has(event.source) guard: ${code_jira_when}"
fi

# Provider present
if jira_overlay_has "${CODE_HARNESS}" ".providers[]" "providers/jira-ro.yaml"; then
  assert_pass "code-jira-provider-present"
else
  assert_fail "code-jira-provider-present" "providers/jira-ro.yaml not in Jira overlay"
fi

# Profile present
if jira_overlay_has "${CODE_HARNESS}" ".openshell.profiles[]" "profiles/fullsend-jira-ro.yaml"; then
  assert_pass "code-jira-profile-present"
else
  assert_fail "code-jira-profile-present" "profiles/fullsend-jira-ro.yaml not in Jira overlay"
fi

# JIRA_TOKEN not in sandbox env
if jira_overlay_has "${CODE_HARNESS}" "(.env.sandbox // {}) | keys | .[]" "JIRA_TOKEN"; then
  assert_fail "code-jira-token-not-in-sandbox" "JIRA_TOKEN found in sandbox env"
else
  assert_pass "code-jira-token-not-in-sandbox"
fi

# JIRA_TOKEN and JIRA_USER_EMAIL in runner env (post-code writes the
# code-stage update to the Jira issue from the runner)
if jira_overlay_has "${CODE_HARNESS}" "(.env.runner // {}) | keys | .[]" "JIRA_TOKEN"; then
  assert_pass "code-jira-token-in-runner"
else
  assert_fail "code-jira-token-in-runner" "JIRA_TOKEN missing from runner env (needed for post-code Jira write)"
fi
if jira_overlay_has "${CODE_HARNESS}" "(.env.runner // {}) | keys | .[]" "JIRA_USER_EMAIL"; then
  assert_pass "code-jira-email-in-runner"
else
  assert_fail "code-jira-email-in-runner" "JIRA_USER_EMAIL missing from runner env (needed for post-code Jira write)"
fi

check_runner_mapping "${CODE_HARNESS}" code JIRA_TOKEN '${FULLSEND_JIRA_TOKEN}'
check_runner_mapping "${CODE_HARNESS}" code JIRA_USER_EMAIL '${FULLSEND_JIRA_EMAIL}'
check_runner_mapping "${CODE_HARNESS}" code FULLSEND_DIR '${FULLSEND_DIR}'

# JIRA_USER_EMAIL reaches the sandbox through the expanded host file, not
# env.sandbox (optional for a service account; #1900).
if grep -qF 'export JIRA_USER_EMAIL=' "${REPO_ROOT}/env/jira/code.env" \
  && ! jira_overlay_has "${CODE_HARNESS}" "(.env.sandbox // {}) | keys | .[]" "JIRA_USER_EMAIL"; then
  assert_pass "code-jira-email-in-sandbox-host-file"
else
  assert_fail "code-jira-email-in-sandbox-host-file" "JIRA_USER_EMAIL must come from env/jira/code.env, not env.sandbox"
fi

# JIRA_BASE_URL in sandbox env (non-secret, needed for API URLs)
if jira_overlay_has "${CODE_HARNESS}" "(.env.sandbox // {}) | keys | .[]" "JIRA_BASE_URL"; then
  assert_pass "code-jira-base-url-in-sandbox"
else
  assert_fail "code-jira-base-url-in-sandbox" "JIRA_BASE_URL missing from sandbox env"
fi

# No .issue-context.json host_file (prefetch removed)
if jira_overlay_has "${CODE_HARNESS}" ".host_files[]?.dest" ".issue-context.json"; then
  assert_fail "code-no-issue-context-host-file" ".issue-context.json still in host_files"
else
  assert_pass "code-no-issue-context-host-file"
fi

# JIRA_ISSUE_CONTEXT_FILE not in runner env (prefetch removed)
if jira_overlay_has "${CODE_HARNESS}" "(.env.runner // {}) | keys | .[]" "JIRA_ISSUE_CONTEXT_FILE"; then
  assert_fail "code-no-issue-context-file-env" "JIRA_ISSUE_CONTEXT_FILE still in runner env"
else
  assert_pass "code-no-issue-context-file-env"
fi

# ---------------------------------------------------------------------------
# Skill-level tests: sandbox curl commands use the opaque provider
# placeholder with Basic auth (--user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}")
# when JIRA_USER_EMAIL is set, and Bearer auth (--oauth2-bearer) when it
# is empty (#1900). The real token never enters the sandbox; JIRA_TOKEN in
# these commands is the provider-supplied placeholder that OpenShell
# replaces at the proxy boundary.
# ---------------------------------------------------------------------------
SKILL_FILES=(
  "${REPO_ROOT}/skills/jira-forge/SKILL.md"
  "${REPO_ROOT}/skills/issue-labels/jira/SKILL.md"
  "${REPO_ROOT}/skills/jira-components/SKILL.md"
  "${REPO_ROOT}/skills/code-implementation/SKILL.md"
)

for skill_file in "${SKILL_FILES[@]}"; do
  skill_name="$(basename "$(dirname "${skill_file}")")"
  test_name="skill-${skill_name}-basic-auth-placeholder"

  if [ ! -f "${skill_file}" ]; then
    assert_fail "${test_name}" "${skill_file} not found"
    continue
  fi

  # The selection lines trim JIRA_USER_EMAIL into JIRA_EMAIL, then pick
  # Basic auth (--user email:token) only when the trimmed email is
  # non-empty, else Bearer (--oauth2-bearer token), so no curl sends Basic
  # auth with an empty or whitespace-only email.
  if grep -qF -- 'JIRA_EMAIL="${JIRA_USER_EMAIL:-}"; JIRA_EMAIL="${JIRA_EMAIL//[[:space:]]/}"' "${skill_file}" \
    && grep -qF -- 'JIRA_AUTH_FLAG=--oauth2-bearer; test -n "${JIRA_EMAIL}" && JIRA_AUTH_FLAG=--user' "${skill_file}" \
    && grep -qF -- 'JIRA_AUTH="${JIRA_EMAIL:+${JIRA_EMAIL}:}${JIRA_TOKEN}"' "${skill_file}"; then
    assert_pass "${test_name}"
  else
    assert_fail "${test_name}" "missing the Basic/Bearer selection lines in ${skill_file}"
  fi
done

# The sandbox command hook cannot analyse a command substitution in the
# email trim and blocks the whole snippet (#1995). The trim must stay a
# parameter expansion in every skill.
if cmdsub_files="$(grep -rlF -- 'JIRA_EMAIL="$(' "${REPO_ROOT}/skills")"; then
  assert_fail "skill-jira-email-no-command-substitution" \
    "JIRA_EMAIL=\"\$( found in: ${cmdsub_files//$'\n'/ }"
else
  assert_pass "skill-jira-email-no-command-substitution"
fi

# The same hook blocks the issue-key command substitution, and blocks a
# shell variable inside --data-urlencode, so the Jira skills derive the key
# with parameter expansion and write the project key into JQL literally.
for skill_file in "${SKILL_FILES[@]}"; do
  skill_name="$(basename "$(dirname "${skill_file}")")"
  [ -f "${skill_file}" ] || continue  # already reported above
  if grep -qF -- 'ISSUE_KEY=$(' "${skill_file}"; then
    assert_fail "skill-${skill_name}-issue-key-expansion" "ISSUE_KEY=\$( found in ${skill_file}"
  else
    assert_pass "skill-${skill_name}-issue-key-expansion"
  fi
  if grep -qE -- '--data-urlencode "jql=[^"]*\$' "${skill_file}"; then
    assert_fail "skill-${skill_name}-jql-literal" "a shell variable inside --data-urlencode \"jql=...\" in ${skill_file}"
  else
    assert_pass "skill-${skill_name}-jql-literal"
  fi
done

# Every Jira curl uses the selected auth, and none passes --user directly.
for skill_file in "${SKILL_FILES[@]}"; do
  skill_name="$(basename "$(dirname "${skill_file}")")"
  test_name="skill-${skill_name}-auth-mode-selection"

  if [ ! -f "${skill_file}" ]; then
    continue  # already reported above
  fi

  if grep -qF -- '--user "' "${skill_file}"; then
    assert_fail "${test_name}" "a curl in ${skill_file} passes --user directly instead of the selected auth"
  elif grep -E 'curl ' "${skill_file}" | grep -F 'JIRA_' | grep -qvF '"${JIRA_AUTH_FLAG}" "${JIRA_AUTH}"'; then
    assert_fail "${test_name}" "a Jira curl in ${skill_file} does not use \"\${JIRA_AUTH_FLAG}\" \"\${JIRA_AUTH}\""
  else
    assert_pass "${test_name}"
  fi
done

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
# JIRA_API_URL (#1876): REST calls go to the API URL fullsend provides (the
# Atlassian API gateway), falling back to JIRA_BASE_URL.
# ---------------------------------------------------------------------------
# The sandbox can reach the gateway.
if yq -e '.endpoints[] | select(.host == "api.atlassian.com" and .port == 443)' \
  "${REPO_ROOT}/profiles/fullsend-jira-ro.yaml" >/dev/null; then
  assert_pass "profile-allows-api-gateway"
else
  assert_fail "profile-allows-api-gateway" "api.atlassian.com:443 not in fullsend-jira-ro endpoints"
fi

# JIRA_API_URL reaches the sandbox through an expanded .env.d host file and
# never through env.runner/env.sandbox: a ${VAR} there fails the run when the
# host variable is unset, and older fullsend releases do not set it.
for harness_file in "${TRIAGE_HARNESS}" "${CODE_HARNESS}"; do
  harness_name="$(basename "${harness_file}" .yaml)"
  env_src="$(jira_overlay_field "${harness_file}" \
    '.host_files[]? | select(.dest == "*/.env.d/*" and .expand == true) | .src')"
  found=false
  while IFS= read -r src; do
    [[ -n "${src}" && -f "${REPO_ROOT}/${src}" ]] || continue
    if grep -qxF 'export JIRA_API_URL="${JIRA_API_URL}"' "${REPO_ROOT}/${src}"; then
      found=true
    fi
  done <<< "${env_src}"
  if ${found}; then
    assert_pass "${harness_name}-jira-api-url-in-env-file"
  else
    assert_fail "${harness_name}-jira-api-url-in-env-file" "no expanded .env.d host file exports JIRA_API_URL"
  fi

  if jira_overlay_has "${harness_file}" \
    '((.env.runner // {}) + (.env.sandbox // {})) | to_entries | .[] | .key + "=" + .value' \
    "JIRA_API_URL"; then
    assert_fail "${harness_name}-jira-api-url-not-required" "JIRA_API_URL must not be referenced in env.runner/env.sandbox"
  else
    assert_pass "${harness_name}-jira-api-url-not-required"
  fi
done

# Sandbox skills send REST calls to JIRA_API_URL with the site URL fallback.
for skill_file in "${SKILL_FILES[@]}"; do
  skill_name="$(basename "$(dirname "${skill_file}")")"
  test_name="skill-${skill_name}-uses-jira-api-url"
  [ -f "${skill_file}" ] || continue  # already reported above
  if grep -qF '${JIRA_BASE_URL}/rest/api' "${skill_file}"; then
    assert_fail "${test_name}" "REST call uses \${JIRA_BASE_URL} instead of \${JIRA_API_URL:-\${JIRA_BASE_URL}}"
  elif grep -qF '"${JIRA_API_URL:-${JIRA_BASE_URL}}/rest/api/3/' "${skill_file}"; then
    assert_pass "${test_name}"
  else
    assert_fail "${test_name}" "no REST call through \${JIRA_API_URL:-\${JIRA_BASE_URL}}"
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
echo "All harness Jira tests passed"
