#!/usr/bin/env bash
# shellcheck shell=bash
# gitlab-prioritize-ops.lib.sh — GitLab forge operations for prioritize scripts.
#
# Bundled into pre-prioritize.sh and post-prioritize.sh via prioritize-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by forge_parse_issue_url):
#   REPO           — plain project path (e.g., "group/project")
#   REPO_ENCODED   — URL-encoded project path (e.g., "group%2Fproject")
#   ISSUE_NUMBER   — issue IID
#   GITLAB_HOST    — API host (e.g., "gitlab.com")
#
# Expected env vars:
#   ISSUE_URL      — HTML URL of the issue
#   GITLAB_TOKEN   — GitLab personal/project access token

[[ -n "${GITLAB_PRIORITIZE_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_PRIORITIZE_OPS_SH_LOADED=1

# shellcheck source=gitlab-host-validation.lib.sh
source "${BASH_SOURCE[0]%/*}/gitlab-host-validation.lib.sh"

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call forge_parse_issue_url first" >&2
    return 1
  fi
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@"
}

# --- URL handling ---

forge_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+/-/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitLab pattern: $(_gha_sanitize "${ISSUE_URL}")" >&2
    return 1
  fi
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  _validate_gitlab_host "${host}" || return 1
}

forge_parse_issue_url() {
  # Extract host, project path, and issue IID from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/issues/42
  GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  REPO=$(echo "${ISSUE_URL}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
  REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
}

# --- Project board operations ---

forge_update_project_scores() {
  # GitLab custom fields API integration deferred. The GitLab Issues API
  # ignores unknown top-level keys (returns 200 silently), so writing RICE
  # field names there is a no-op. The correct Custom Fields API requires
  # field IDs resolved at runtime and is only available on Premium/Ultimate.
  # Scores are always available in the reasoning comment.
  echo "::notice::GitLab custom fields not yet implemented — scores are in comment only"
  return 0
}

# --- Comments ---

# Posts a new note whose first line is <marker>. Each run appends a new
# note at the end of the thread; earlier marked notes are never edited
# (fullsend-ai/fullsend#9334). The GitHub door appends the same way once
# fullsend-ai/fullsend#9399 lands.
forge_post_sticky_comment() {
  : "${GITLAB_TOKEN:?GITLAB_TOKEN must be set}"
  local body="$1"
  local marker="$2"
  _gitlab_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
    --data-urlencode "body=${marker}
${body}" > /dev/null \
    || { echo "::warning::Failed to post comment" >&2; return 1; }
}
