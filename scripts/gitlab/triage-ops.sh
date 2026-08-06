#!/usr/bin/env bash
# scripts/gitlab/triage-ops.sh — GitLab forge operations for triage scripts.
#
# Sourced by pre-triage.sh and post-triage.sh. All functions use curl
# against the GitLab REST API.
#
# Expected globals (set by the caller before sourcing):
#   REPO           — url-encoded project path (e.g., "group%2Fproject")
#   ISSUE_NUMBER   — issue IID
#   GITLAB_HOST    — API host (e.g., "gitlab.com")
#
# Expected env vars:
#   ISSUE_URL      — HTML URL of the issue
#   GITLAB_TOKEN   — GitLab personal/project access token

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  curl --fail --silent --show-error \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@"
}

# --- URL handling ---

forge_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+/-/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitLab pattern: ${ISSUE_URL}" >&2
    return 1
  fi
}

forge_parse_issue_url() {
  # Extract host, project path, and issue IID from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/issues/42
  GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  local project_path
  project_path=$(echo "${ISSUE_URL}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
  REPO=$(printf '%s' "${project_path}" | jq -sRr @uri)
  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
}

# --- Labels ---

forge_add_label() {
  local label="$1"
  local current_labels
  current_labels=$(_gitlab_api GET "/projects/${REPO}/issues/${ISSUE_NUMBER}" | jq -r '[.labels[]] | join(",")')
  if [[ -n "${current_labels}" ]]; then
    current_labels="${current_labels},${label}"
  else
    current_labels="${label}"
  fi
  _gitlab_api PUT "/projects/${REPO}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "labels=${current_labels}" > /dev/null
}

forge_remove_label() {
  local label="$1"
  local current_labels
  current_labels=$(_gitlab_api GET "/projects/${REPO}/issues/${ISSUE_NUMBER}" | jq -r '[.labels[] | select(. != "'"${label}"'")] | join(",")')
  _gitlab_api PUT "/projects/${REPO}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "labels=${current_labels}" > /dev/null 2>/dev/null || true
}

forge_strip_labels() {
  local labels_to_strip=("$@")
  local current_labels
  current_labels=$(_gitlab_api GET "/projects/${REPO}/issues/${ISSUE_NUMBER}" | jq -r '[.labels[]] | join(",")')

  local filtered=""
  IFS=',' read -ra current_array <<< "${current_labels}"
  for current in "${current_array[@]}"; do
    local should_strip=false
    for strip in "${labels_to_strip[@]}"; do
      if [[ "${current}" == "${strip}" ]]; then
        should_strip=true
        break
      fi
    done
    if [[ "${should_strip}" != "true" ]]; then
      if [[ -n "${filtered}" ]]; then
        filtered="${filtered},${current}"
      else
        filtered="${current}"
      fi
    fi
  done

  _gitlab_api PUT "/projects/${REPO}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "labels=${filtered}" > /dev/null
}

forge_verify_labels_stripped() {
  local labels_to_check=("$@")
  local current_labels
  current_labels=$(_gitlab_api GET "/projects/${REPO}/issues/${ISSUE_NUMBER}" 2>/dev/null | jq -r '[.labels[]] | join(",")' 2>/dev/null || echo "VERIFY_FAILED")

  if [[ "${current_labels}" == "VERIFY_FAILED" ]]; then
    echo "ERROR: cannot verify label state — API call failed" >&2
    return 1
  fi

  local remaining=""
  IFS=',' read -ra current_array <<< "${current_labels}"
  for current in "${current_array[@]}"; do
    for check in "${labels_to_check[@]}"; do
      if [[ "${current}" == "${check}" ]]; then
        if [[ -n "${remaining}" ]]; then
          remaining="${remaining}, ${current}"
        else
          remaining="${current}"
        fi
      fi
    done
  done

  if [[ -n "${remaining}" ]]; then
    echo "ERROR: triage labels still present after reset: ${remaining}" >&2
    return 1
  fi
}

forge_list_repo_labels() {
  _gitlab_api GET "/projects/${REPO}/labels?per_page=100" 2>/dev/null | jq -r '.[].name' || true
}

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  _gitlab_api POST "/projects/${REPO}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${color}" > /dev/null 2>/dev/null || true
}

# --- Comments (notes in GitLab) ---

forge_post_comment() {
  local body="$1"
  _gitlab_api POST "/projects/${REPO}/issues/${ISSUE_NUMBER}/notes" \
    --data-urlencode "body=${body}" > /dev/null
}

forge_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  local marked_body="${marker}
${body}"

  # Search for existing note with the marker.
  local notes
  notes=$(_gitlab_api GET "/projects/${REPO}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=asc" 2>/dev/null) || notes="[]"

  local note_id
  note_id=$(echo "${notes}" | jq -r --arg marker "${marker}" \
    '[.[] | select(.body | startswith($marker))][0].id // empty')

  if [[ -n "${note_id}" ]]; then
    _gitlab_api PUT "/projects/${REPO}/issues/${ISSUE_NUMBER}/notes/${note_id}" \
      --data-urlencode "body=${marked_body}" > /dev/null
  else
    _gitlab_api POST "/projects/${REPO}/issues/${ISSUE_NUMBER}/notes" \
      --data-urlencode "body=${marked_body}" > /dev/null
  fi
}

# --- Issues ---

forge_close_issue() {
  local _reason="$1"  # GitLab has no close-reason API; accepted for interface parity
  _gitlab_api PUT "/projects/${REPO}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "state_event=close" > /dev/null
}

forge_create_issue() {
  local target_repo="$1"
  local title="$2"
  local body="$3"
  local encoded_target
  encoded_target=$(printf '%s' "${target_repo}" | jq -sRr @uri)
  local response
  response=$(_gitlab_api POST "/projects/${encoded_target}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description=${body}") || {
    echo "${response}"
    return 1
  }
  echo "${response}" | jq -r '.web_url'
}
