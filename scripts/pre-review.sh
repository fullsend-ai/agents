#!/usr/bin/env bash
# GENERATED from pre-review.src.sh — DO NOT EDIT. Run: make script-build
# pre-review.sh — Validate review inputs before the agent runs.
#
# Runs on the host via the harness pre_script mechanism.
#
# Required environment variables (set by the harness forge section):
#   PR_URL         — HTML URL of the PR/MR
#   FULLSEND_FORGE — "github" or "gitlab"
#
# Optional environment variables:
#   REVIEW_TOKEN        — token for PR state checks and comments
#   REVIEW_SKIP_AUTHORS — comma-separated author list to skip
set -euo pipefail

: "${PR_URL:?PR_URL must be set}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/review-ops.lib.sh
# BEGIN bundled: lib/review-ops.lib.sh
# shellcheck shell=bash
# review-ops.lib.sh — Forge-dispatch wrapper for review operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${REVIEW_OPS_SH_LOADED:-}" ]] && return 0
REVIEW_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-review-ops.lib.sh
# shellcheck shell=bash
# github-review-ops.lib.sh — GitHub forge operations for review scripts.
#
# Bundled into pre-review.sh and post-review.sh via review-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by forge_parse_pr_url):
#   REPO         — owner/repo (e.g., "org/repo")
#   PR_NUMBER    — PR number
#
# Expected env vars:
#   PR_URL       — HTML URL of the pull request
#   REVIEW_TOKEN — GitHub token with pull-requests read/write scope

[[ -n "${GITHUB_REVIEW_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_REVIEW_OPS_SH_LOADED=1

# --- URL handling ---

forge_validate_pr_url() {
  if [[ ! "${PR_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/pull/[0-9]+$ ]]; then
    echo "ERROR: PR_URL does not match expected GitHub pattern: $(_gha_sanitize "${PR_URL}")" >&2
    return 1
  fi
}

forge_parse_pr_url() {
  REPO=$(echo "${PR_URL}" | sed 's|https://github.com/||; s|/pull/.*||')
  PR_NUMBER=$(basename "${PR_URL}")
}

# --- PR queries ---

forge_get_pr_state() {
  GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json state --jq '.state' 2>/dev/null || true
}

forge_get_pr_author() {
  GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json author --jq '.author.login' 2>/dev/null || true
}

forge_get_pr_info() {
  GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json state,isDraft 2>/dev/null || {
    jq -n '{state: "UNKNOWN", isDraft: false}'
    return
  }
}

forge_get_pr_files() {
  # Use the paginated /pulls/{n}/files REST endpoint rather than the
  # `gh pr view --json files` summary field: issue #2093 found empty
  # results correlated with recent merge-commit updates and hypothesized
  # asynchronous diff computation, but GitHub does not document that as
  # an API contract. The files endpoint reflects the computed diff more
  # directly.
  local files
  if ! files=$(GH_TOKEN="${REVIEW_TOKEN}" gh api \
    "repos/${REPO}/pulls/${PR_NUMBER}/files" --paginate --jq '.[].filename' 2>/dev/null); then
    return 1
  fi
  [[ -n "${files}" ]] && printf '%s\n' "${files}"
}

# --- PR mutations ---

forge_post_review() {
  local result_file="$1"
  fullsend post-review \
    --forge github \
    --repo "${REPO}" \
    --pr "${PR_NUMBER}" \
    --token "${REVIEW_TOKEN}" \
    --result "${result_file}"
}

forge_close_pr() {
  local comment="$1"
  GH_TOKEN="${REVIEW_TOKEN}" gh pr close "${PR_NUMBER}" \
    --repo "${REPO}" \
    --comment "${comment}" || true
}

# --- Comments ---

forge_post_comment() {
  local body="$1"
  printf '%s' "${body}" | GH_TOKEN="${REVIEW_TOKEN}" gh issue comment "${PR_NUMBER}" \
    --repo "${REPO}" --body-file -
}

forge_get_recent_redispatch_comments() {
  local marker="$1"
  local window_seconds="$2"
  GH_TOKEN="${REVIEW_TOKEN}" gh api \
    "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    --paginate 2>/dev/null \
    | jq -s --arg marker "${marker}" --argjson window "${window_seconds}" \
    'add // [] | [.[] | select(.body | contains($marker))
          | select(.created_at > (now - $window | strftime("%Y-%m-%dT%H:%M:%SZ")))]
     | length'
}

# --- Labels ---

forge_add_label() {
  local label="$1"
  GH_TOKEN="${REVIEW_TOKEN}" gh api "repos/${REPO}/issues/${PR_NUMBER}/labels" \
    -f "labels[]=${label}" --silent || \
    echo "::warning::Failed to add label '$(_gha_sanitize "${label}")'"
}

forge_remove_label() {
  local label="$1"
  local encoded
  encoded=$(printf '%s' "${label}" | jq -sRr @uri)
  GH_TOKEN="${REVIEW_TOKEN}" gh api "repos/${REPO}/issues/${PR_NUMBER}/labels/${encoded}" \
    -X DELETE --silent 2>/dev/null || true
}

forge_remove_label_edit() {
  local label="$1"
  GH_TOKEN="${REVIEW_TOKEN}" gh pr edit "${PR_NUMBER}" --repo "${REPO}" \
    --remove-label "${label}" 2>/dev/null || true
}

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  GH_TOKEN="${REVIEW_TOKEN}" gh label create "${name}" --repo "${REPO}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

forge_add_label_edit() {
  local label="$1"
  GH_TOKEN="${REVIEW_TOKEN}" gh pr edit "${PR_NUMBER}" --repo "${REPO}" \
    --add-label "${label}" || true
}

forge_list_repo_labels() {
  GH_TOKEN="${REVIEW_TOKEN}" gh api "repos/${REPO}/labels" --paginate --jq '.[].name' 2>/dev/null || true
}

# Returns 0 if an authorized human has already approved the current HEAD,
# 1 otherwise. Fail-closed on any API error or incomplete signal.
#
# Two independent gates, both required (lessons from PR #305):
#   1. GitHub's reviewDecision does not indicate an outstanding block.
#      reviewDecision is only ever CHANGES_REQUESTED, REVIEW_REQUIRED,
#      APPROVED, or null — it is null whenever the base branch has no
#      required-review branch-protection rule configured, regardless of
#      how many humans have approved. Null/empty is therefore treated as
#      "no required-review protection configured", not as rejection, and
#      falls through to Gate 2. CHANGES_REQUESTED and REVIEW_REQUIRED
#      still fail closed unconditionally. Because a null reviewDecision
#      can't be relied on to reflect an outstanding CHANGES_REQUESTED
#      review, Gate 2 additionally scans each reviewer's latest review
#      itself and fails closed if any is blocking.
#   2. At least one APPROVED review on the current HEAD SHA comes from a
#      non-bot, non-author User with write/maintain/admin permission.
#      author_association is not used: MEMBER does not imply write access
#      when the org default_repository_permission is read.
forge_has_authorized_human_approval() {
  local pr_json
  pr_json=$(GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json reviewDecision,headRefOid,author 2>/dev/null) || return 1
  [[ -n "${pr_json}" ]] || return 1

  local review_decision head_sha author_login
  review_decision=$(printf '%s' "${pr_json}" | jq -r '.reviewDecision // empty') || return 1
  head_sha=$(printf '%s' "${pr_json}" | jq -r '.headRefOid // empty') || return 1
  author_login=$(printf '%s' "${pr_json}" | jq -r '.author.login // empty') || return 1

  [[ -n "${head_sha}" ]] || return 1
  [[ -n "${author_login}" ]] || return 1

  case "${review_decision}" in
    CHANGES_REQUESTED|REVIEW_REQUIRED)
      return 1
      ;;
  esac

  local reviews
  reviews=$(GH_TOKEN="${REVIEW_TOKEN}" gh api \
    "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate 2>/dev/null) || return 1

  # Each reviewer's *effective* review ignores COMMENTED and PENDING —
  # GitHub's own merge-gating semantics do the same: a later comment does
  # not clear an outstanding CHANGES_REQUESTED. Only the latest of
  # APPROVED/CHANGES_REQUESTED/DISMISSED per reviewer counts.
  local blocking_count
  blocking_count=$(printf '%s' "${reviews}" | jq -r -s '
    add // []
    | map(select(.user != null and (.user.login // "") != ""))
    | map(select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))
    | group_by(.user.login)
    | map(max_by(.submitted_at // ""))
    | map(select(.state == "CHANGES_REQUESTED"))
    | length
  ') || return 1
  [[ "${blocking_count}" == "0" ]] || return 1

  # Candidates use each reviewer's *effective* review — the same
  # group_by/max_by pipeline as blocking_count above — so a reviewer's
  # earlier APPROVED row is not reused once a later review (even a
  # since-dismissed CHANGES_REQUESTED) has superseded it. Matching only
  # the raw APPROVED row's own commit_id/state, without regard to
  # whether it is still that reviewer's latest state, would let a stale
  # approval authorize the skip after the reviewer's standing changed.
  local candidates
  candidates=$(printf '%s' "${reviews}" | jq -r -s --arg sha "${head_sha}" --arg author "${author_login}" '
    add // []
    | map(select(.user != null and (.user.login // "") != ""))
    | map(select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))
    | group_by(.user.login)
    | map(max_by(.submitted_at // ""))
    | [.[]
      | select(
          .state == "APPROVED"
          and .commit_id == $sha
          and .user.login != $author
          and (.user.type // "") == "User"
          and ((.user.login | endswith("[bot]")) | not)
        )
      | .user.login]
    | unique[]
  ') || return 1

  [[ -n "${candidates}" ]] || return 1

  # Re-fetch HEAD SHA immediately before trusting the match. If the call
  # fails or the SHA moved, fall closed — do not reuse the earlier snapshot.
  local current_sha
  current_sha=$(GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json headRefOid --jq '.headRefOid' 2>/dev/null) || return 1
  [[ -n "${current_sha}" ]] || return 1
  [[ "${current_sha}" == "${head_sha}" ]] || return 1

  local login encoded perm_json role
  while IFS= read -r login; do
    [[ -n "${login}" ]] || continue
    encoded=$(printf '%s' "${login}" | jq -sRr @uri) || continue
    perm_json=$(GH_TOKEN="${REVIEW_TOKEN}" gh api \
      "repos/${REPO}/collaborators/${encoded}/permission" 2>/dev/null) || continue
    role=$(printf '%s' "${perm_json}" | jq -r '.role_name // empty') || continue
    case "${role}" in
      admin|maintain|write)
        echo "Authorized human approval on HEAD from ${login} (role=${role})"
        return 0
        ;;
    esac
  done <<< "${candidates}"

  return 1
}
# END bundled: lib/github-review-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-review-ops.lib.sh
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
# BEGIN bundled: lib/gitlab-host-validation.lib.sh
# shellcheck shell=bash
# gitlab-host-validation.lib.sh — Shared host validation for GitLab ops.
#
# Validates a hostname against CI_SERVER_HOST, a GitLab CI predefined
# variable set automatically by the runner.
#
# Fails closed: rejects when CI_SERVER_HOST is not set.
#
# Sourced by all gitlab-*-ops.lib.sh files and inlined by the bundler.

[[ -n "${GITLAB_HOST_VALIDATION_SH_LOADED:-}" ]] && return 0
GITLAB_HOST_VALIDATION_SH_LOADED=1

if ! declare -F _gha_sanitize >/dev/null 2>&1; then
  _gha_sanitize() {
    printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'
  }
fi

_validate_gitlab_host() {
  local host="$1"
  if [[ -z "${CI_SERVER_HOST:-}" ]]; then
    echo "ERROR: CI_SERVER_HOST is not set (set by GitLab CI runner)" >&2
    return 1
  fi
  if [[ ! "${CI_SERVER_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: CI_SERVER_HOST contains invalid characters" >&2
    return 1
  fi
  if [[ "${host,,}" != "${CI_SERVER_HOST,,}" ]]; then
    echo "ERROR: GitLab host '$(_gha_sanitize "${host}")' does not match CI_SERVER_HOST" >&2
    return 1
  fi
}
# END bundled: lib/gitlab-host-validation.lib.sh

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
# "-0700") into epoch seconds. Returns nothing (not even null) when the
# input is empty, not a string, or does not match — callers must treat a
# missing result as a parse failure and fail closed.
_GITLAB_ISO8601_EPOCH_JQ_DEF='
def iso8601_epoch:
  if . == null or (length) == 0 then empty
  else
    ((capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$")?) // null) as $m
    | if $m == null then empty
      else
        ($m.base + "Z" | fromdateiso8601) as $base
        | (if $m.tz == "Z" then 0
           else
             ($m.tz[1:] | gsub(":"; "")) as $digits
             | (($digits[0:2] | tonumber) * 3600 + ($digits[2:4] | tonumber) * 60) as $mag
             | (if ($m.tz | startswith("-")) then -$mag else $mag end)
           end) as $offset
        | $base - $offset
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
#      backdates commits or replays them from another branch. Gate 3
#      itself spans a versions call, paginated notes, and a member
#      lookup, so HEAD is re-checked one final time immediately before
#      returning success — a push during that window must not be
#      authorized against the earlier snapshot.
forge_has_authorized_human_approval() {
  local mr_data
  mr_data=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" 2>/dev/null) || return 1
  [[ -n "${mr_data}" ]] || return 1

  local sha author_login
  sha=$(printf '%s' "${mr_data}" | jq -r '.sha // empty') || return 1
  author_login=$(printf '%s' "${mr_data}" | jq -r '.author.username // empty') || return 1
  [[ -n "${sha}" ]] || return 1
  [[ -n "${author_login}" ]] || return 1

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
  local versions version_epoch
  versions=$(_gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/versions" 2>/dev/null) || return 1
  [[ -n "${versions}" ]] || return 1
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
      # Gate 3 spans a versions call, up to 50 paginated notes pages, and a
      # member lookup — re-check HEAD one last time immediately before
      # trusting the result. A push during that window that replaces the
      # approved HEAD with an unreviewed one must not be authorized here.
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
# END bundled: lib/gitlab-review-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/review-ops.lib.sh

forge_validate_pr_url
echo "::notice::🔗 Review target: $(_gha_sanitize "${PR_URL}")"
forge_parse_pr_url

echo "Input validation passed:"
echo "  PR_NUMBER=${PR_NUMBER}"
echo "  REPO=${REPO}"
echo "  PR_URL=${PR_URL}"

# ---------------------------------------------------------------------------
# Check PR state — skip review on merged or closed PRs
# ---------------------------------------------------------------------------
if [[ -z "${REVIEW_TOKEN:-}" ]]; then
  echo "No token available — skipping PR state check"
  exit 0
fi

PR_STATE="$(forge_get_pr_state)"

if [[ -n "${PR_STATE}" && "${PR_STATE}" != "OPEN" ]]; then
  echo "::notice::PR #${PR_NUMBER} is ${PR_STATE} — skipping review"

  STATE_LOWER="$(echo "${PR_STATE}" | tr '[:upper:]' '[:lower:]')"
  COMMENT_BODY="Review skipped — this PR is already **${STATE_LOWER}**.

The \`/fs-review\` command only reviews open PRs/MRs.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-review check</sub>"

  forge_post_comment "${COMMENT_BODY}" 2>/dev/null || true

  exit 0
fi

# ---------------------------------------------------------------------------
# Check author skip list — exit early if PR author is in REVIEW_SKIP_AUTHORS
# ---------------------------------------------------------------------------
if [[ -n "${REVIEW_SKIP_AUTHORS:-}" ]]; then
  PR_AUTHOR="$(forge_get_pr_author)"

  if [[ -n "${PR_AUTHOR}" ]]; then
    IFS=',' read -ra _SKIP_LIST <<< "${REVIEW_SKIP_AUTHORS}"
    for _entry in "${_SKIP_LIST[@]}"; do
      read -r _entry <<< "${_entry}"  # trim whitespace
      if [[ "${_entry,,}" == "${PR_AUTHOR,,}" ]]; then
        _SAFE_AUTHOR="$(_gha_sanitize "${PR_AUTHOR}")"
        echo "::notice::PR #${PR_NUMBER} authored by ${_SAFE_AUTHOR} — skipping review (REVIEW_SKIP_AUTHORS)"

        COMMENT_BODY="Review skipped — PR author **${PR_AUTHOR}** is in the \`REVIEW_SKIP_AUTHORS\` list.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-review check</sub>"

        forge_post_comment "${COMMENT_BODY}" 2>/dev/null || true

        exit 0
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# Deepen shallow clone for git history analysis (risk assessment Tier 2).
# When REVIEW_GIT_FETCH_DEPTH is unset, default to "0" (full unshallow) if
# risk assessment is enabled — the Tier 2 sub-agent needs full git history.
# Explicit values always take precedence.
# ---------------------------------------------------------------------------
if [[ -z "${REVIEW_GIT_FETCH_DEPTH+set}" && "${REVIEW_RISK_ASSESSMENT_ENABLED:-false}" == "true" ]]; then
  REVIEW_GIT_FETCH_DEPTH="0"
fi
if [[ "${REVIEW_GIT_FETCH_DEPTH:-}" == "0" ]]; then
  _TARGET_DIR="${REPO_DIR:-${GITHUB_WORKSPACE:-.}/target-repo}"
  if [[ ! -d "${_TARGET_DIR}" ]]; then
    echo "::warning::Clone-deepening skipped — target directory '${_TARGET_DIR}' not found"
  elif git -C "${_TARGET_DIR}" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
    echo "Deepening shallow clone for git history analysis..."
    if [[ "${FULLSEND_FORGE}" == "github" && -n "${GH_TOKEN:-}" && -n "${REPO_FULL_NAME:-}" ]]; then
      git -C "${_TARGET_DIR}" \
        -c "http.extraheader=Authorization: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 -w0)" \
        fetch --unshallow "https://github.com/${REPO_FULL_NAME}.git" 2>/dev/null \
        && echo "Clone deepened successfully" \
        || echo "::warning::Failed to deepen clone — Tier 2 risk signals may be degraded"
    else
      echo "::warning::Cannot deepen clone — missing credentials or unsupported forge"
    fi
  fi
fi

echo "PR #${PR_NUMBER} is open — proceeding with review agent"
