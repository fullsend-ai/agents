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

# Parses a GitLab ISO-8601 timestamp (optional fractional seconds, and
# either a trailing "Z" or a numeric UTC offset such as "+02:00" or
# "-0700") into epoch milliseconds. Fractional seconds are captured (not
# discarded) and truncated to millisecond resolution so two timestamps
# that differ only within the same UTC second still compare correctly —
# whole-second truncation previously let an approval note timestamped in
# the same second as, but milliseconds before, a matching MR version's
# created_at be treated as covering that version. Returns nothing (not
# even null) when the input is empty, not a string, or does not match —
# callers must treat a missing result as a parse failure and fail closed.
_GITLAB_ISO8601_EPOCH_JQ_DEF='
def iso8601_epoch:
  if . == null or (length) == 0 then empty
  else
    ((capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.(?<frac>[0-9]+))?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$")?) // null) as $m
    | if $m == null then empty
      else
        ($m.base + "Z" | fromdateiso8601) as $base
        | (if $m.tz == "Z" then 0
           else
             ($m.tz[1:] | gsub(":"; "")) as $digits
             | (($digits[0:2] | tonumber) * 3600 + ($digits[2:4] | tonumber) * 60) as $mag
             | (if ($m.tz | startswith("-")) then -$mag else $mag end)
           end) as $offset
        | ((($m.frac // "0") + "000")[0:3] | tonumber) as $frac_ms
        | ($base - $offset) * 1000 + $frac_ms
      end
  end;
'

# Returns 0 if an authorized human has already approved the current HEAD,
# 1 otherwise. Fail-closed on any API error or incomplete signal.
#
# Three independent gates, all required:
#   1. GitLab's approvals.approved is true — respects approval rules.
#   2. At least one non-bot, non-author approver has Developer or higher
#      (access_level >= 30). approved=true with zero required approvals
#      and an empty approved_by list does not satisfy this gate.
#   3. That approver has an "approved this merge request" system note
#      timestamped at or after the MR version whose head_commit_sha
#      matches current HEAD was created. approved_by is MR-level, not
#      SHA-scoped: when a project disables reset_approvals_on_push, an
#      approval recorded before earlier pushes still appears here after
#      HEAD has moved. Gate 3 binds the approval to HEAD the same way
#      GitHub's `commit_id == sha` does — using GitLab's own record of
#      when the SHA became MR HEAD (the diff version's created_at), not
#      the commit's committer date, which is not push-ordered and can
#      predate a still-standing approval note under a workflow that
#      backdates commits or replays them from another branch.
forge_has_authorized_human_approval() {
  local mr_data
  mr_data=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null) || return 1
  [[ -n "${mr_data}" ]] || return 1

  local sha author_login
  sha=$(printf '%s' "${mr_data}" | jq -r '.sha // empty') || return 1
  author_login=$(printf '%s' "${mr_data}" | jq -r '.author.username // empty') || return 1
  [[ -n "${sha}" ]] || return 1

  local approvals
  approvals=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/approvals" 2>/dev/null) || return 1
  [[ -n "${approvals}" ]] || return 1

  local approved
  approved=$(printf '%s' "${approvals}" | jq -r '.approved // false') || return 1
  if [[ "${approved}" != "true" ]]; then
    return 1
  fi

  local candidates
  candidates=$(printf '%s' "${approvals}" | jq -r --arg author "${author_login}" '
    [.approved_by[]? | .user
      | select(
          . != null
          and (.username // "") != ""
          and .username != $author
          and ((.bot // false) | not)
          and ((.username | endswith("_bot")) | not)
        )
      | "\(.id)\t\(.username)"]
    | unique[]
  ') || return 1

  [[ -n "${candidates}" ]] || return 1

  # Re-fetch SHA immediately before trusting the match. Fail closed if the
  # call errors or HEAD moved since the first read.
  local current_sha
  current_sha=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null \
    | jq -r '.sha // empty') || return 1
  [[ -n "${current_sha}" ]] || return 1
  [[ "${current_sha}" == "${sha}" ]] || return 1

  # Gate 3: resolve when the current HEAD SHA became the MR's HEAD — per
  # GitLab's own diff-version record, not the commit's committer date
  # (not push-ordered; see the doc comment above) — then require a
  # qualifying approval note timestamped at or after that. Fail closed if
  # the call errors, no version matches current HEAD, or its timestamp is
  # unavailable/unparseable.
  # Paginate versions the same way notes are paginated below: per_page=100,
  # capped pages, so a matching version on a later page can't be missed by
  # truncation. Without this, GitLab's default page size (20, unordered by
  # this request) could hide the newest matching version behind an older
  # one still on page 1, understating version_epoch and letting a stale
  # approval satisfy gate 3 (fail-open).
  local versions="[]" version_page=1 version_max_pages=50 version_last_batch_count=-1
  while [[ "${version_page}" -le "${version_max_pages}" ]]; do
    local version_batch version_batch_count
    version_batch=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/versions?per_page=100&page=${version_page}" 2>/dev/null) || return 1
    [[ -n "${version_batch}" ]] || return 1
    version_batch_count=$(printf '%s' "${version_batch}" | jq 'length') || return 1
    [[ "${version_batch_count}" =~ ^[0-9]+$ ]] || return 1
    versions=$(jq -c -n --argjson a "${versions}" --argjson b "${version_batch}" '$a + $b') || return 1
    version_last_batch_count="${version_batch_count}"
    [[ "${version_batch_count}" -lt 100 ]] && break
    version_page=$((version_page + 1))
  done
  [[ -n "${versions}" ]] || return 1
  # If the loop only stopped because version_max_pages was exhausted — not
  # because a short (< 100 item) final page ended pagination naturally —
  # the last fetched page was still full. The version list may be missing
  # pages beyond the cap, so version_epoch below could understate the true
  # max(created_at) and let a stale approval satisfy gate 3 (fail-open).
  # Fail closed instead of trusting a possibly-truncated list.
  if [[ "${version_page}" -gt "${version_max_pages}" && "${version_last_batch_count}" -eq 100 ]]; then
    return 1
  fi

  local version_epoch
  version_epoch=$(printf '%s' "${versions}" | jq -r --arg sha "${current_sha}" '
    '"${_GITLAB_ISO8601_EPOCH_JQ_DEF}"'
    [.[]? | select(.head_commit_sha == $sha) | (.created_at | iso8601_epoch)]
    | if length > 0 then max else empty end
  ') || return 1
  [[ "${version_epoch}" =~ ^[0-9]+$ ]] || return 1

  # Paginate notes so a qualifying approval on a busy MR isn't missed by
  # only checking the most recent page. Capped and fail-closed on overflow
  # like forge_list_repo_labels: if the cap is hit, any note beyond it is
  # simply not considered, and gate 3 below fails closed as usual.
  local notes="[]" page=1 max_pages=50
  while [[ "${page}" -le "${max_pages}" ]]; do
    local batch batch_count
    batch=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/notes?per_page=100&sort=desc&page=${page}" 2>/dev/null) || return 1
    [[ -n "${batch}" ]] || return 1
    batch_count=$(printf '%s' "${batch}" | jq 'length') || return 1
    [[ "${batch_count}" =~ ^[0-9]+$ ]] || return 1
    notes=$(jq -c -n --argjson a "${notes}" --argjson b "${batch}" '$a + $b') || return 1
    [[ "${batch_count}" -lt 100 ]] && break
    page=$((page + 1))
  done
  [[ -n "${notes}" ]] || return 1

  local id username member access approval_epoch
  while IFS=$'\t' read -r id username; do
    [[ -n "${id}" ]] || continue

    approval_epoch=$(printf '%s' "${notes}" | jq -r --arg user "${username}" '
      '"${_GITLAB_ISO8601_EPOCH_JQ_DEF}"'
      [.[]? | select(.system == true and .body == "approved this merge request" and (.author.username // "") == $user)
            | (.created_at | iso8601_epoch)]
      | if length > 0 then max else empty end
    ') || continue
    [[ "${approval_epoch}" =~ ^[0-9]+$ ]] || continue
    [ "${approval_epoch}" -ge "${version_epoch}" ] || continue

    member=$(_gitlab_api GET "/projects/${REPO_ENCODED}/members/all/${id}" 2>/dev/null) || continue
    access=$(printf '%s' "${member}" | jq -r '.access_level // 0') || continue
    if [[ "${access}" =~ ^[0-9]+$ ]] && [ "${access}" -ge 30 ]; then
      # Re-fetch SHA one more time immediately before trusting the result,
      # shrinking the remaining TOCTOU window between the earlier re-fetch
      # (line ~297) and the versions/notes/member lookups that ran since.
      local final_sha
      final_sha=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null \
        | jq -r '.sha // empty') || return 1
      [[ -n "${final_sha}" ]] || return 1
      [[ "${final_sha}" == "${current_sha}" ]] || return 1
      echo "Authorized human approval from ${username} (access_level=${access}) on HEAD ${current_sha}"
      return 0
    fi
  done <<< "${candidates}"

  return 1
}
