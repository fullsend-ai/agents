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

# Resolve still-open review threads on GitLab whose only comments are outdated
# inline comments authored by the review agent. Best-effort: failures log a
# warning and return success so they cannot block posting the new review.
forge_resolve_outdated_review_threads() {
  if [[ -z "${REPO_ENCODED:-}" || -z "${PR_NUMBER:-}" ]]; then
    return 0
  fi

  local mr_info current_sha
  mr_info=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null) || mr_info="{}"
  current_sha=$(echo "${mr_info}" | jq -r '.diff_refs.head_sha // .sha // empty' 2>/dev/null) || current_sha=""
  if [[ -z "${current_sha}" ]]; then
    return 0
  fi

  local current_user bot_user_id bot_username
  current_user=$(_gitlab_api GET "/user" 2>/dev/null) || current_user="{}"
  bot_user_id=$(echo "${current_user}" | jq -r '.id // empty' 2>/dev/null) || bot_user_id=""
  bot_username=$(echo "${current_user}" | jq -r '.username // empty' 2>/dev/null) || bot_username=""

  local page=1 all_discussions="[]"
  while [[ "${page}" -le 10 ]]; do
    local response
    response=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/discussions?per_page=100&page=${page}" 2>/dev/null) || {
      echo "::warning::Failed to fetch MR discussions for #${PR_NUMBER} while resolving outdated threads" >&2
      break
    }
    if [[ -z "${response}" || "${response}" == "[]" || "${response}" != "["* ]]; then
      break
    fi
    all_discussions=$(jq -c -s '.[0] + .[1]' <<< "${all_discussions} ${response}" 2>/dev/null) || break
    local count
    count=$(jq 'length' <<< "${response}" 2>/dev/null) || count=0
    [[ "${count}" -lt 100 ]] && break
    page=$((page + 1))
  done

  local discussion_ids
  discussion_ids=$(echo "${all_discussions}" | jq -r --arg current_sha "${current_sha}" --arg bot_id "${bot_user_id}" --arg bot_user "${bot_username}" '
    .[]
    | select(.id != null)
    | .notes |= (map(select(.system != true)) // [])
    | select(.notes | type == "array" and length > 0)
    | select(.notes | any(.resolvable == true and .resolved == false))
    | select(
        if ($bot_id != "") then
          .notes | all((.author.id | tostring) == $bot_id or (.author.username // "" | ascii_downcase) == ($bot_user | ascii_downcase))
        else
          .notes | all((.author.username // "" | test("(^|[-_])bot([-_]|$)|\\[bot\\]$|fullsend"; "i")) or (.body // "" | test("<!--[ ]*fullsend|🤖 Fullsend"; "i")))
        end
      )
    | select(
        if ($current_sha != "") then
          (.notes[0].position.head_sha // empty) != "" and .notes[0].position.head_sha != $current_sha
        else
          false
        end
      )
    | .id
  ' 2>/dev/null) || discussion_ids=""

  if [[ -z "${discussion_ids}" ]]; then
    return 0
  fi

  local resolved=0 failed=0
  while IFS= read -r disc_id; do
    [[ -z "${disc_id}" ]] && continue
    if _gitlab_api PUT "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/discussions/${disc_id}?resolved=true" >/dev/null 2>&1; then
      resolved=$((resolved + 1))
    else
      failed=$((failed + 1))
      echo "::warning::Failed to resolve review thread $(_gha_sanitize "${disc_id}")"
    fi
  done <<< "${discussion_ids}"

  if [[ "${resolved}" -gt 0 ]]; then
    echo "Resolved ${resolved} outdated review-agent thread(s)"
  fi
  if [[ "${failed}" -gt 0 ]]; then
    echo "::warning::Failed to resolve ${failed} outdated review thread(s)"
  fi

  return 0
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
