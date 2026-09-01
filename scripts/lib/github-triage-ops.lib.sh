#!/usr/bin/env bash
# shellcheck shell=bash
# github-triage-ops.lib.sh — GitHub forge operations for triage scripts.
#
# Bundled into pre-triage.sh and post-triage.sh via triage-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by tracker_parse_issue_url):
#   REPO         — owner/repo (e.g., "org/repo")
#   ISSUE_NUMBER — issue number
#
# Expected env vars:
#   ISSUE_URL    — HTML URL of the issue
#   GH_TOKEN     — GitHub token with issues read/write scope

[[ -n "${GITHUB_TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_TRIAGE_OPS_SH_LOADED=1

# --- URL handling ---

tracker_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected pattern: ${ISSUE_URL}" >&2
    return 1
  fi
}

tracker_parse_issue_url() {
  REPO=$(echo "${ISSUE_URL}" | sed 's|https://github.com/||; s|/issues/.*||')
  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
}

# --- Labels ---

tracker_add_label() {
  local label="$1"
  local endpoint="repos/${REPO}/issues/${ISSUE_NUMBER}/labels"
  local err_output
  if ! err_output=$(gh api "${endpoint}" -f "labels[]=${label}" --silent 2>&1); then
    echo "ERROR: failed to add label '${label}' to issue #${ISSUE_NUMBER} (POST ${endpoint})" >&2
    [[ -n "${err_output}" ]] && echo "ERROR: ${err_output}" >&2
    return 1
  fi
}

tracker_remove_label() {
  local label="$1"
  local encoded
  encoded=$(printf '%s' "${label}" | jq -sRr @uri)
  gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/labels/${encoded}" -X DELETE --silent 2>/dev/null || true
}

tracker_strip_labels() {
  local labels=("$@")
  for label in "${labels[@]}"; do
    local encoded
    encoded=$(printf '%s' "${label}" | jq -sRr @uri)
    gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/labels/${encoded}" -X DELETE --silent 2>/dev/null || true
  done
}

tracker_verify_labels_stripped() {
  local labels=("$@")
  local labels_json
  labels_json=$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s .)

  local remaining
  remaining=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/labels" 2>/dev/null \
    | jq -r --argjson check "${labels_json}" \
        '[.[] | select(.name as $n | $check | index($n)) | .name] | join(", ")' \
    || echo "VERIFY_FAILED")

  if [[ "${remaining}" == "VERIFY_FAILED" ]]; then
    echo "ERROR: cannot verify label state — API call failed" >&2
    return 1
  fi
  if [[ -n "${remaining}" ]]; then
    echo "ERROR: triage labels still present after reset: ${remaining}" >&2
    return 1
  fi
}

tracker_list_repo_labels() {
  gh api "repos/${REPO}/labels" --paginate --jq '.[].name' 2>/dev/null || true
}

tracker_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  gh label create "${name}" --repo "${REPO}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

# --- Comments ---

tracker_post_comment() {
  local body="$1"
  printf '%s' "${body}" | gh issue comment "${ISSUE_NUMBER}" --repo "${REPO}" --body-file -
}

tracker_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  printf '%s' "${body}" | fullsend post-comment --repo "${REPO}" --number "${ISSUE_NUMBER}" --marker "${marker}" --token "${GH_TOKEN}" --result -
}

# --- Issues ---

tracker_close_issue() {
  local reason="$1"
  gh issue close "${ISSUE_NUMBER}" --repo "${REPO}" --reason "${reason}"
}

tracker_create_issue() {
  local target_repo="$1"
  local title="$2"
  local body="$3"
  local err_file
  err_file=$(mktemp)
  local url
  if ! url=$(gh issue create --repo "${target_repo}" --title "${title}" --body "${body}" 2>"${err_file}"); then
    local err_msg
    err_msg=$(cat "${err_file}")
    rm -f "${err_file}"
    echo "GitHub API error: failed to create issue in ${target_repo}: ${err_msg}" >&2
    return 1
  fi
  rm -f "${err_file}"
  echo "${url}"
}

tracker_dispatch_triage() {
  local issue_url="$1"
  local target_repo target_number
  target_repo=$(echo "${issue_url}" | sed 's|https://github.com/||; s|/issues/.*||')
  target_number=$(basename "${issue_url}")
  local endpoint="repos/${target_repo}/issues/${target_number}/labels"
  if ! gh api "${endpoint}" -f "labels[]=ready-for-triage" --silent 2>/dev/null; then
    echo "::warning::Failed to add ready-for-triage label to ${issue_url}" >&2
    return 1
  fi
}
