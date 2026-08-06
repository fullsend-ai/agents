#!/usr/bin/env bash
# scripts/github/triage-ops.sh — GitHub forge operations for triage scripts.
#
# Sourced by pre-triage.sh and post-triage.sh. All functions use the gh CLI
# and the GitHub REST API.
#
# Expected globals (set by the caller before sourcing):
#   REPO         — owner/repo (e.g., "org/repo")
#   ISSUE_NUMBER — issue number
#
# Expected env vars:
#   ISSUE_URL    — HTML URL of the issue
#   GH_TOKEN     — GitHub token with issues read/write scope

# --- URL handling ---

forge_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected pattern: ${ISSUE_URL}" >&2
    return 1
  fi
}

forge_parse_issue_url() {
  REPO=$(echo "${ISSUE_URL}" | sed 's|https://github.com/||; s|/issues/.*||')
  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
}

# --- Labels ---

forge_add_label() {
  local label="$1"
  local endpoint="repos/${REPO}/issues/${ISSUE_NUMBER}/labels"
  local err_output
  if ! err_output=$(gh api "${endpoint}" -f "labels[]=${label}" --silent 2>&1); then
    echo "ERROR: failed to add label '${label}' to issue #${ISSUE_NUMBER} (POST ${endpoint})" >&2
    [[ -n "${err_output}" ]] && echo "ERROR: ${err_output}" >&2
    return 1
  fi
}

forge_remove_label() {
  local label="$1"
  local encoded
  encoded=$(printf '%s' "${label}" | jq -sRr @uri)
  gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/labels/${encoded}" -X DELETE --silent 2>/dev/null || true
}

forge_strip_labels() {
  local labels=("$@")
  for label in "${labels[@]}"; do
    gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/labels/${label}" -X DELETE --silent 2>/dev/null || true
  done
}

forge_verify_labels_stripped() {
  local labels=("$@")
  local jq_filter
  jq_filter='[.[] | select('
  local first=true
  for label in "${labels[@]}"; do
    ${first} || jq_filter="${jq_filter} or "
    jq_filter="${jq_filter}.name == \"${label}\""
    first=false
  done
  jq_filter="${jq_filter}) | .name] | join(\", \")"

  local remaining
  remaining=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/labels" --jq "${jq_filter}" 2>/dev/null || echo "VERIFY_FAILED")

  if [[ "${remaining}" == "VERIFY_FAILED" ]]; then
    echo "ERROR: cannot verify label state — API call failed" >&2
    return 1
  fi
  if [[ -n "${remaining}" ]]; then
    echo "ERROR: triage labels still present after reset: ${remaining}" >&2
    return 1
  fi
}

forge_list_repo_labels() {
  gh api "repos/${REPO}/labels" --paginate --jq '.[].name' 2>/dev/null || true
}

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  gh label create "${name}" --repo "${REPO}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

# --- Comments ---

forge_post_comment() {
  local body="$1"
  printf '%s' "${body}" | gh issue comment "${ISSUE_NUMBER}" --repo "${REPO}" --body-file -
}

forge_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  printf '%s' "${body}" | fullsend post-comment --repo "${REPO}" --number "${ISSUE_NUMBER}" --marker "${marker}" --token "${GH_TOKEN}" --result -
}

# --- Issues ---

forge_close_issue() {
  local reason="$1"
  gh issue close "${ISSUE_NUMBER}" --repo "${REPO}" --reason "${reason}"
}

forge_create_issue() {
  local target_repo="$1"
  local title="$2"
  local body="$3"
  gh issue create --repo "${target_repo}" --title "${title}" --body "${body}" 2>&1
}
