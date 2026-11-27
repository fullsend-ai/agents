#!/usr/bin/env bash
# shellcheck shell=bash
# gitlab-review-ops.lib.sh — GitLab forge operations for review scripts.
#
# Bundled into pre-review.sh and post-review.sh via review-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by forge_parse_pr_url):
#   REPO           — plain project path (e.g., "group/project")
#   REPO_ENCODED   — URL-encoded project path (e.g., "group%2Fproject")
#   PR_NUMBER      — merge request IID
#   GITLAB_HOST    — API host (e.g., "gitlab.com")
#
# Expected env vars:
#   PR_URL         — HTML URL of the merge request
#   REVIEW_TOKEN   — GitLab personal/project access token
#
# Token scopes: REVIEW_TOKEN requires minimum scopes:
#   - api (read/write merge requests, labels, notes)
#   Prefer project access tokens scoped to the target project over
#   personal access tokens with broader access.

[[ -n "${GITLAB_REVIEW_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_REVIEW_OPS_SH_LOADED=1

# shellcheck source=gitlab-host-validation.lib.sh
source "${BASH_SOURCE[0]%/*}/gitlab-host-validation.lib.sh"

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call forge_parse_pr_url first" >&2
    return 1
  fi
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${REVIEW_TOKEN}" \
    --request "${method}" \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@"
}

# --- URL handling ---

forge_validate_pr_url() {
  if [[ ! "${PR_URL}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+/-/merge_requests/[0-9]+$ ]]; then
    echo "ERROR: PR_URL does not match expected GitLab MR pattern: $(_gha_sanitize "${PR_URL}")" >&2
    return 1
  fi
  local host
  host=$(echo "${PR_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  _validate_gitlab_host "${host}" || return 1
}

forge_parse_pr_url() {
  # Extract host, project path, and MR IID from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/merge_requests/42
  GITLAB_HOST=$(echo "${PR_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  REPO=$(echo "${PR_URL}" | sed -E 's|^https://[^/]+/(.+)/-/merge_requests/[0-9]+$|\1|')
  REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
  PR_NUMBER=$(basename "${PR_URL}")
}

# --- PR queries ---

forge_get_pr_state() {
  local mr_data
  mr_data=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null) || { echo ""; return; }
  local state
  state=$(echo "${mr_data}" | jq -r '.state // empty')
  # Normalize to GitHub-style states for script compatibility
  case "${state}" in
    opened) echo "OPEN" ;;
    closed) echo "CLOSED" ;;
    merged) echo "MERGED" ;;
    locked) echo "CLOSED" ;;
    *) echo "UNKNOWN" ;;
  esac
}

forge_get_pr_author() {
  local mr_data
  mr_data=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null) || { echo ""; return; }
  echo "${mr_data}" | jq -r '.author.username // empty'
}

# Fails when the labels cannot be read.
forge_get_pr_labels() {
  local mr_data
  mr_data=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null) || return 1
  jq -r '.labels[]? // empty' <<< "${mr_data}"
}

forge_get_pr_info() {
  local mr_data
  mr_data=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null) || {
    jq -n '{state: "UNKNOWN", isDraft: false}'
    return
  }
  local state is_draft
  state=$(echo "${mr_data}" | jq -r '.state // empty')
  is_draft=$(echo "${mr_data}" | jq -r '.draft // false')
  if [[ -z "${state}" ]]; then
    jq -n '{state: "UNKNOWN", isDraft: false}'
    return
  fi
  # Normalize to GitHub-compatible JSON shape
  case "${state}" in
    opened) state="OPEN" ;;
    closed) state="CLOSED" ;;
    merged) state="MERGED" ;;
    locked) state="CLOSED" ;;
  esac
  jq -n --arg state "${state}" --argjson isDraft "${is_draft}" \
    '{state: $state, isDraft: $isDraft}'
}

forge_get_pr_files() {
  local response
  response=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/changes" 2>/dev/null) || return
  if echo "${response}" | jq -e '.overflow == true' > /dev/null 2>&1; then
    echo "::warning::MR has too many changes — file list may be truncated (overflow)" >&2
    return 1
  fi
  echo "${response}" | jq -r '.changes[]?.new_path // empty' | sort -u
}

# --- PR mutations ---

forge_post_review() {
  local result_file="$1"
  fullsend post-review \
    --forge gitlab \
    --repo "${REPO}" \
    --pr "${PR_NUMBER}" \
    --token "${REVIEW_TOKEN}" \
    --result "${result_file}"
}

forge_close_pr() {
  local comment="$1"
  # Post the close comment as a note first
  _gitlab_api POST "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/notes" \
    --data-urlencode "body=${comment}" > /dev/null 2>/dev/null || true
  # Then close the MR
  _gitlab_api PUT "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" \
    --data-urlencode "state_event=close" > /dev/null 2>/dev/null || true
}

# --- Comments (notes in GitLab) ---

forge_post_comment() {
  local body="$1"
  _gitlab_api POST "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/notes" \
    --data-urlencode "body=${body}" > /dev/null
}

forge_get_recent_redispatch_comments() {
  local marker="$1"
  local window_seconds="$2"
  local notes
  notes=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/notes?per_page=100&sort=desc" 2>/dev/null) || notes="[]"
  echo "${notes}" | jq --arg marker "${marker}" --argjson window "${window_seconds}" \
    '[.[] | select(.body | contains($marker))
          | select(.created_at | fromdateiso8601 > (now - $window))]
     | length'
}

# GitLab notes do not expose the same GitHub review-comment URL shape. Keep
# the caller forge-neutral and let it fall back to the finding context.
forge_get_finding_comment_links() {
  echo '{}'
}

# GitHub-only: GitLab discussions have no isOutdated equivalent in this
# issue's scope. No-op so post-review can call this unconditionally.
forge_resolve_outdated_review_threads() {
  return 0
}

# --- Finding threads ---
#
# Merge-request discussions in the normalized thread shape that
# forge_reconcile_finding_threads (review-ops.lib.sh) reads; see
# github-review-ops.lib.sh for the field list. The review bot is the
# authenticated review-token user, as for human dismissals. System notes are
# not comments. GitLab returns every note of a discussion, so a thread's
# comments are always complete.

_GITLAB_FINDING_THREAD_NORM='
  def norm:
    if type != "object" or (.id | type) != "string" then null else
    ([ (.notes // [])[] | select(type == "object" and (.system // false) == false) ]) as $notes
    | {
        id,
        url: (if ($notes[0].id | type) == "number" then $pr_url + "#note_" + ($notes[0].id | tostring) else $pr_url end),
        resolved: ($notes[0].resolved == true),
        can_resolve: ($notes[0].resolvable == true),
        comments_complete: true,
        comments: [ $notes[]
                    | ((.author.username // "") | ascii_downcase) as $a
                    | {body: (.body // ""), review_bot: ($a == $actor), own: ($a == $actor)} ]
      } end;
'

_gitlab_review_actor() {
  _gitlab_api GET "/user" 2>/dev/null | jq -r '.username // empty' 2>/dev/null
}

_gitlab_mr_head_sha() {
  _gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null \
    | jq -r '.sha // empty' 2>/dev/null
}

forge_fetch_finding_threads() {
  local actor head page batch count all complete
  actor="$(_gitlab_review_actor)" || return 1
  [[ -n "${actor}" ]] || return 1
  head="$(_gitlab_mr_head_sha)" || return 1
  all='[]'
  complete=false
  page=1
  while [[ "${page}" -le 20 ]]; do
    batch=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/discussions?per_page=100&page=${page}" 2>/dev/null) || return 1
    jq -e 'type == "array"' <<< "${batch}" >/dev/null 2>&1 || return 1
    all=$(jq -c --argjson acc "${all}" '$acc + .' <<< "${batch}") || return 1
    count=$(jq 'length' <<< "${batch}")
    if [[ "${count}" -lt 100 ]]; then
      complete=true
      break
    fi
    page=$((page + 1))
  done
  jq -c --arg pr_url "${PR_URL}" --arg actor "${actor,,}" --arg head "${head}" --argjson complete "${complete}" \
    "${_GITLAB_FINDING_THREAD_NORM}"'{complete: $complete, head_sha: $head, threads: [ .[] | norm | select(. != null) ]}' \
    <<< "${all}"
}

forge_fetch_finding_thread() {
  local thread_id="$1" actor head response
  actor="$(_gitlab_review_actor)" || return 1
  [[ -n "${actor}" ]] || return 1
  head="$(_gitlab_mr_head_sha)" || return 1
  if ! response=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/discussions/${thread_id}" 2>&1); then
    # A discussion deleted since the first read is gone, not unreadable.
    if [[ "${response}" == *"error: 404"* ]]; then
      jq -nc --arg head "${head}" '{head_sha: $head, thread: null}'
      return 0
    fi
    return 1
  fi
  jq -c --arg pr_url "${PR_URL}" --arg actor "${actor,,}" --arg head "${head}" \
    "${_GITLAB_FINDING_THREAD_NORM}"'{head_sha: $head, thread: norm}' <<< "${response}"
}

forge_reply_finding_thread() {
  local thread_id="$1" body="$2" line safe=""
  # GitLab runs a quick action (/close, /label, ...) from any note line that
  # starts with "/", with the posting token's permissions. The body carries
  # model text derived from untrusted PR content and keeps its newlines, so a
  # leading backslash on such a line stops it parsing as a command while the
  # text still renders as written.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*/ ]]; then
      line="\\${line}"
    fi
    safe+="${line}"$'\n'
  done <<< "${body}"
  body="${safe%$'\n'}"
  _gitlab_api POST "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/discussions/${thread_id}/notes" \
    --data-urlencode "body=${body}" > /dev/null 2>&1
}

forge_resolve_finding_thread() {
  local thread_id="$1"
  _gitlab_api PUT "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/discussions/${thread_id}" \
    --data-urlencode "resolved=true" > /dev/null 2>&1
}

# --- Labels ---

forge_add_label() {
  local label="$1"
  if ! _gitlab_api PUT "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" \
    --data-urlencode "add_labels=${label}" > /dev/null; then
    echo "::warning::Failed to add label '$(_gha_sanitize "${label}")'"
  fi
}

forge_remove_label() {
  local label="$1"
  _gitlab_api PUT "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" \
    --data-urlencode "remove_labels=${label}" > /dev/null 2>/dev/null || true
}

forge_remove_label_checked() {
  _gitlab_api PUT "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" \
    --data-urlencode "remove_labels=$1" > /dev/null 2>&1
}

forge_remove_label_edit() {
  # GitLab uses the same API for label management — no separate "edit" path
  forge_remove_label "$1"
}

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  _gitlab_api POST "/projects/${REPO_ENCODED}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${color}" > /dev/null 2>/dev/null || true
}

forge_add_label_edit() {
  # GitLab uses the same API for label management — no separate "edit" path
  forge_add_label "$1"
}

forge_list_repo_labels() {
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
