#!/usr/bin/env bash
# shellcheck shell=bash
# gitlab-triage-ops.lib.sh — GitLab forge operations for triage scripts.
#
# Bundled into pre-triage.sh and post-triage.sh via triage-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by tracker_parse_issue_url):
#   REPO           — plain project path (e.g., "group/project")
#   REPO_ENCODED   — URL-encoded project path (e.g., "group%2Fproject")
#   ISSUE_NUMBER   — issue IID
#   GITLAB_HOST    — API host (e.g., "gitlab.com")
#
# Expected env vars:
#   ISSUE_URL      — HTML URL of the issue
#   GITLAB_TOKEN   — GitLab personal/project access token
#
# Token scopes: GITLAB_TOKEN requires minimum scopes:
#   - api (read/write issues, labels, notes, merge requests)
#   Prefer project access tokens scoped to the target project over
#   personal access tokens with broader access.
#
# Token identity: GITLAB_TOKEN must resolve to an identity the fullsend
# GitLab dispatcher's bot detection recognizes (project access token or
# configured bot user). Label writes use PUT /issues/:iid which bumps
# updated_at; the dispatcher's isBotEvent filter prevents re-triggering
# triage only if the token owner is recognized as a bot.

[[ -n "${GITLAB_TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_TRIAGE_OPS_SH_LOADED=1

# shellcheck source=gitlab-host-validation.lib.sh
source "${BASH_SOURCE[0]%/*}/gitlab-host-validation.lib.sh"

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call tracker_parse_issue_url first" >&2
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

_gitlab_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call tracker_parse_issue_url first" >&2
    return 1
  fi
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
  local err_file
  err_file=$(mktemp)
  local raw
  raw=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "GitLab API error: curl failed — $(cat "${err_file}")" >&2
    rm -f "${err_file}"
    return 1
  }
  rm -f "${err_file}"
  local http_code
  http_code=$(echo "${raw}" | tail -1)
  local body
  body=$(echo "${raw}" | sed '$d')
  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    echo "GitLab API error (HTTP ${http_code}): ${body}" >&2
    return 1
  fi
  echo "${body}"
}

# --- URL handling ---

tracker_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+/-/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitLab pattern: $(_gha_sanitize "${ISSUE_URL}")" >&2
    return 1
  fi
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  _validate_gitlab_host "${host}" || return 1
}

tracker_parse_issue_url() {
  # Extract host, project path, and issue IID from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/issues/42
  GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  REPO=$(echo "${ISSUE_URL}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
  REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
}

# --- Labels ---

tracker_add_label() {
  local label="$1"
  if ! _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "add_labels=${label}" > /dev/null; then
    echo "ERROR: failed to add label '${label}' to issue #${ISSUE_NUMBER} via PUT /projects/${REPO}/issues/${ISSUE_NUMBER}" >&2
    return 1
  fi
}

tracker_remove_label() {
  local label="$1"
  _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "remove_labels=${label}" > /dev/null 2>/dev/null || true
}

tracker_strip_labels() {
  local labels=("$@")
  for label in "${labels[@]}"; do
    _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" \
      --data-urlencode "remove_labels=${label}" > /dev/null 2>/dev/null || true
  done
}

tracker_verify_labels_stripped() {
  local labels=("$@")
  local current_labels
  current_labels=$(_gitlab_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" 2>/dev/null | jq -r '[.labels[]] | join(",")' 2>/dev/null || echo "VERIFY_FAILED")

  if [[ "${current_labels}" == "VERIFY_FAILED" ]]; then
    echo "ERROR: cannot verify label state — API call failed" >&2
    return 1
  fi

  local remaining=""
  IFS=',' read -ra current_array <<< "${current_labels}"
  for current in "${current_array[@]}"; do
    for check in "${labels[@]}"; do
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

tracker_list_repo_labels() {
  local page=1 max_pages=50
  while [[ "${page}" -le "${max_pages}" ]]; do
    local batch
    batch=$(_gitlab_api GET "/projects/${REPO_ENCODED}/labels?per_page=100&page=${page}" 2>/dev/null) || break
    local count
    count=$(echo "${batch}" | jq 'length') || break
    [[ "${count}" -eq 0 ]] && break
    echo "${batch}" | jq -r '.[].name'
    page=$((page + 1))
  done
}

tracker_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  _gitlab_api POST "/projects/${REPO_ENCODED}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${color}" > /dev/null 2>/dev/null || true
}

# --- Bot identity (for sticky-comment author filtering) ---

_GITLAB_BOT_USERNAME=""

_gitlab_bot_username() {
  if [[ -z "${_GITLAB_BOT_USERNAME}" ]]; then
    _GITLAB_BOT_USERNAME=$(_gitlab_api GET "/user" 2>/dev/null | jq -r '.username // empty')
    if [[ -z "${_GITLAB_BOT_USERNAME}" ]]; then
      echo "ERROR: failed to determine GitLab token owner via GET /user" >&2
      return 1
    fi
  fi
  echo "${_GITLAB_BOT_USERNAME}"
}

# --- Comments (notes in GitLab) ---

tracker_post_comment() {
  local body="$1"
  _gitlab_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
    --data-urlencode "body=${body}" > /dev/null
}

tracker_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  local marked_body="${marker}
${body}"

  local bot_user
  bot_user=$(_gitlab_bot_username) || {
    _gitlab_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
      --data-urlencode "body=${marked_body}" > /dev/null
    return
  }

  local notes="[]"
  local page=1 max_pages=50
  while [[ "${page}" -le "${max_pages}" ]]; do
    local batch
    batch=$(_gitlab_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=asc&page=${page}" 2>/dev/null) || break
    local count
    count=$(echo "${batch}" | jq 'length') || break
    [[ "${count}" -eq 0 ]] && break
    notes=$(echo "${notes}" "${batch}" | jq -s 'add')
    page=$((page + 1))
  done

  local match
  match=$(echo "${notes}" | jq --arg marker "${marker}" --arg user "${bot_user}" \
    '[.[] | select(.author.username == $user and (.body | startswith($marker)))][0] // empty')

  local note_id
  note_id=$(echo "${match}" | jq -r '.id // empty')

  if [[ -n "${note_id}" ]]; then
    local old_body
    old_body=$(echo "${match}" | jq -r '.body // empty')
    local stripped_old
    local escaped_marker
    escaped_marker=$(printf '%s' "${marker}" | sed 's/[].[*^$()+?{|\\]/\\&/g; s|/|\\/|g')
    stripped_old=$(echo "${old_body}" | sed "1{/^${escaped_marker}$/d;}")
    if [[ -n "${stripped_old}" ]]; then
      local history
      history=$(printf '\n\n<details>\n<summary>Previous run</summary>\n\n%s\n\n</details>' "${stripped_old}")
      local max_len=60000
      if [[ ${#history} -gt ${max_len} ]]; then
        history="${history:0:${max_len}}
...(truncated)"
      fi
      marked_body="${marked_body}${history}"
    fi
    _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes/${note_id}" \
      --data-urlencode "body=${marked_body}" > /dev/null
  else
    _gitlab_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
      --data-urlencode "body=${marked_body}" > /dev/null
  fi
}

# --- Issues ---

tracker_close_issue() {
  local _reason="$1"  # GitLab has no close-reason API; accepted for interface parity
  if ! _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "state_event=close" > /dev/null; then
    echo "ERROR: failed to close issue #${ISSUE_NUMBER} in ${REPO}" >&2
    return 1
  fi
}

tracker_create_issue() {
  local target_repo="$1"
  local title="$2"
  local body="$3"
  local encoded_target
  encoded_target=$(printf '%s' "${target_repo}" | jq -sRr @uri)
  local response
  response=$(_gitlab_api_with_status POST "/projects/${encoded_target}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description=${body}") || {
    echo "GitLab API error: failed to create issue in ${target_repo}" >&2
    return 1
  }
  echo "${response}" | jq -r '.web_url'
}
