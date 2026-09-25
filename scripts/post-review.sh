#!/usr/bin/env bash
# GENERATED from post-review.src.sh — DO NOT EDIT. Run: make script-build
# Post-script: post the review agent's result to the forge (GitHub/GitLab).
#
# Runs on the GitHub Actions / GitLab CI runner AFTER the sandbox is destroyed.
# CWD is runDir.
#
# This script is the sole enforcement point for protected-path checks:
# if the PR touches sensitive paths, an "approve" action is downgraded
# to "comment" so only a human can grant approval.
#
# Required environment variables:
#   REVIEW_TOKEN                      — token with pull-requests:write on the target repo
#   PR_URL                            — HTML URL of the PR/MR
#   FULLSEND_FORGE                    — "github" or "gitlab"
#   REVIEW_FINDING_SEVERITY_THRESHOLD — minimum severity for findings
#                                       (info|low|medium|high|critical);
#                                       default supplied by harness/review.yaml
#   REVIEW_PROTECTED_PATHS            — comma-separated protected path prefixes,
#                                       or empty string to opt out; required
#                                       (non-empty-or-explicitly-empty) for
#                                       approve actions; default supplied by
#                                       harness/review.yaml
#
# Exit codes:
#   0 — review posted
#   1 — error (review not posted or fallback comment posted)
set -euo pipefail

: "${REVIEW_TOKEN:?REVIEW_TOKEN is required}"
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
#   1. GitHub's reviewDecision is APPROVED — handles latest-per-reviewer,
#      outstanding CHANGES_REQUESTED, CODEOWNERS, and required reviews.
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

  if [[ "${review_decision}" != "APPROVED" || -z "${head_sha}" ]]; then
    return 1
  fi

  local reviews
  reviews=$(GH_TOKEN="${REVIEW_TOKEN}" gh api \
    "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate 2>/dev/null) || return 1

  local candidates
  candidates=$(printf '%s' "${reviews}" | jq -r -s --arg sha "${head_sha}" --arg author "${author_login}" '
    add // []
    | map(select(.user != null and (.user.login // "") != ""))
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
# END bundled: lib/gitlab-review-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/review-ops.lib.sh

forge_validate_pr_url
forge_parse_pr_url

echo "::add-mask::${REVIEW_TOKEN}"

# Temp file cleanup: accumulate files to remove on exit so later traps
# don't overwrite earlier ones.
CLEANUP_FILES=()
trap 'rm -f "${CLEANUP_FILES[@]}"' EXIT

# Refuse to post reviews on merged or closed PRs.
# Also fetch draft status — draft PRs must not receive ready-for-merge.
PR_INFO=$(forge_get_pr_info)
PR_STATE=$(echo "${PR_INFO}" | jq -r '.state')
PR_IS_DRAFT=$(echo "${PR_INFO}" | jq -r '.isDraft')
if [ "${PR_STATE}" != "OPEN" ]; then
  if [ "${PR_STATE}" = "UNKNOWN" ]; then
    echo "::warning::Could not determine PR state (API failure) — skipping review"
    exit 0
  fi
  echo "PR is ${PR_STATE}, skipping review"

  STATE_LOWER="$(echo "${PR_STATE}" | tr '[:upper:]' '[:lower:]')"
  COMMENT_BODY="Review skipped — this PR is already **${STATE_LOWER}**.

The \`/fs-review\` command only reviews open PRs/MRs.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> post-review check</sub>"

  forge_post_comment "${COMMENT_BODY}" 2>/dev/null || true

  exit 0
fi

# Find the agent result — prefer the validated iteration when set.
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent. No containment check
# (realpath / prefix guard) is applied here; the value is trusted from the
# external harness. If the trust model changes, add a realpath prefix check.
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  if [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  elif [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/result.json"
  else
    echo "::error::FULLSEND_VALIDATED_ITERATION_DIR is set but contains neither agent-result.json nor result.json" >&2
    exit 1
  fi
else
  RESULT_FILE=$(find .  -maxdepth 4 -path '*/iteration-*/output/agent-result.json' | sort -V | tail -1)
fi

if [ -z "${RESULT_FILE}" ] || [ ! -f "${RESULT_FILE}" ]; then
  echo "::error::No agent-result.json found — posting failure notice"
  echo '{"action":"failure","reason":"agent-no-output"}' | \
    forge_post_review -
  exit 1
fi

echo "Using result: ${RESULT_FILE}"

# ---------------------------------------------------------------------------
# Severity filtering: drop findings below the configured threshold.
# Defense-in-depth — the agent should already have filtered, but the
# post-script enforces it. The filter runs before ACTION is read so
# that verdict recalculation (if all findings are removed) is possible.
# ---------------------------------------------------------------------------
REVIEW_FINDING_SEVERITY_THRESHOLD="${REVIEW_FINDING_SEVERITY_THRESHOLD:-}"
case "${REVIEW_FINDING_SEVERITY_THRESHOLD}" in
  info|low|medium|high|critical) ;;
  *) # Sanitize before interpolating into a workflow command. Strip raw
     # newlines, then strip every '%' and ':' character outright rather than
     # matching specific multi-char tokens (e.g. "%0A", "::") — matching
     # fixed-width tokens is not idempotent and can be bypassed by adjacent
     # fragments reassembling after a single pass (e.g. "%0%0aA" -> "%0A",
     # ':::error:::' -> '::error::'). Removing every occurrence of a single
     # character in one pass can't reassemble into that character.
     sanitized="${REVIEW_FINDING_SEVERITY_THRESHOLD//$'\n'/}"
     sanitized="${sanitized//$'\r'/}"
     sanitized="${sanitized//%/}"
     sanitized="${sanitized//:/}"
     echo "::error::REVIEW_FINDING_SEVERITY_THRESHOLD='${sanitized}' is invalid (expected info|low|medium|high|critical)"
     echo '{"action":"failure","reason":"tool-failure"}' | \
       forge_post_review -
     exit 1 ;;
esac

severity_rank() {
  case "$1" in
    info)     echo 0 ;;
    low)      echo 1 ;;
    medium)   echo 2 ;;
    high)     echo 3 ;;
    critical) echo 4 ;;
    *)        echo 1 ;;
  esac
}

threshold_rank=$(severity_rank "$REVIEW_FINDING_SEVERITY_THRESHOLD")

if jq -e '.findings' "${RESULT_FILE}" >/dev/null 2>&1; then
  original_count=$(jq '.findings | length' "${RESULT_FILE}")
  FILTERED_RESULT=$(mktemp)
  CLEANUP_FILES+=("${FILTERED_RESULT}")
  jq --argjson rank "$threshold_rank" '
    .findings |= [.[] | select(
      (if .severity == "info" then 0
       elif .severity == "low" then 1
       elif .severity == "medium" then 2
       elif .severity == "high" then 3
       elif .severity == "critical" then 4
       else 1 end) >= $rank
    )]
  ' "${RESULT_FILE}" > "${FILTERED_RESULT}"
  filtered_count=$(jq '.findings | length' "${FILTERED_RESULT}")

  if [ "${filtered_count}" -lt "${original_count}" ]; then
    echo "Severity filter (threshold=${REVIEW_FINDING_SEVERITY_THRESHOLD}): kept ${filtered_count}/${original_count} findings"
    RESULT_FILE="${FILTERED_RESULT}"

    # If filtering removed all findings, delete the empty findings array
    # (minItems: 1 in the schema). For request-changes/reject, also
    # downgrade to comment — zero findings with a blocking verdict is
    # semantically wrong. The threshold is absolute: even actionable
    # findings are filtered (#1046). Use "comment" (not "approve") so
    # the PR gets requires-manual-review, not ready-for-merge.
    if [ "${filtered_count}" -eq 0 ]; then
      original_action=$(jq -r '.action' "${FILTERED_RESULT}")
      DOWNGRADE_RESULT=$(mktemp)
      CLEANUP_FILES+=("${DOWNGRADE_RESULT}")
      if [ "${original_action}" = "request-changes" ] || [ "${original_action}" = "reject" ]; then
        echo "All findings removed by severity filter — downgrading '${original_action}' to 'comment'"
        jq 'del(.findings) | .action = "comment"' "${FILTERED_RESULT}" > "${DOWNGRADE_RESULT}"
      else
        jq 'del(.findings)' "${FILTERED_RESULT}" > "${DOWNGRADE_RESULT}"
      fi
      RESULT_FILE="${DOWNGRADE_RESULT}"
    fi
  else
    rm -f "${FILTERED_RESULT}"
  fi
fi

ACTION=$(jq -r '.action' "${RESULT_FILE}")
# ACTION retains the original value for the entire script — not re-read after protected-path downgrade.

# ---------------------------------------------------------------------------
# Protected-path check: the review agent must not approve PRs that touch
# sensitive paths. If the PR modifies any of these, downgrade "approve" to
# "comment" so only a human can grant approval. This is the sole enforcement
# point — the code agent is free to propose changes to any path.
# ---------------------------------------------------------------------------
DOWNGRADED=false
if [ "${ACTION}" = "approve" ]; then
  # harness/review.yaml always sets REVIEW_PROTECTED_PATHS (with a default,
  # overridable per-repo via harness composition), so an unset value here
  # indicates a genuine misconfiguration rather than an intentional opt-out.
  if [[ "${REVIEW_PROTECTED_PATHS+set}" != "set" ]]; then
    echo "::error::REVIEW_PROTECTED_PATHS is not set — check harness/review.yaml" >&2
    exit 1
  fi

  if [[ -z "${REVIEW_PROTECTED_PATHS}" ]]; then
    # Explicitly empty — operator has opted out of protected-path
    # enforcement for this repo. Distinct from comma-noise below, which
    # is treated as a likely misconfiguration rather than an intentional
    # opt-out.
    echo "::notice::REVIEW_PROTECTED_PATHS is explicitly empty — protected-path enforcement disabled"
    REVIEW_ACTIVE_PROTECTED_PATHS=()
  else
    IFS=',' read -ra REVIEW_ACTIVE_PROTECTED_PATHS <<< "${REVIEW_PROTECTED_PATHS}"
    # Trim leading/trailing whitespace and drop empty entries.
    trimmed=()
    for entry in "${REVIEW_ACTIVE_PROTECTED_PATHS[@]}"; do
      entry="$(echo "${entry}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "${entry}" ]] && trimmed+=("${entry}")
    done
    REVIEW_ACTIVE_PROTECTED_PATHS=()
    [[ ${#trimmed[@]} -gt 0 ]] && REVIEW_ACTIVE_PROTECTED_PATHS=("${trimmed[@]}")
    unset trimmed entry
    if [[ ${#REVIEW_ACTIVE_PROTECTED_PATHS[@]} -eq 0 ]]; then
      # Sanitize before interpolating into a workflow command.
      sanitized_paths="${REVIEW_PROTECTED_PATHS//$'\n'/}"
      sanitized_paths="${sanitized_paths//$'\r'/}"
      sanitized_paths="${sanitized_paths//%/}"
      sanitized_paths="${sanitized_paths//:/}"
      echo "::error::REVIEW_PROTECTED_PATHS=\"${sanitized_paths}\" contains no valid path entries after trimming — likely misconfigured (stray/consecutive commas?). Refusing to continue (fail-closed)." >&2
      unset sanitized_paths
      exit 1
    fi
  fi

  # PR-files fetch and the empty-result guard are an independent safety
  # net (refuse to approve if we can't establish what changed) and must
  # run regardless of whether protected-path enforcement itself is
  # enabled — only the pattern-matching loop below is gated on a
  # non-empty REVIEW_ACTIVE_PROTECTED_PATHS.
  if PR_FILES=$(forge_get_pr_files); then
    PR_FILES_FETCH_FAILED=false
  else
    PR_FILES_FETCH_FAILED=true
    PR_FILES=""
  fi
  if [ "${PR_FILES_FETCH_FAILED}" = true ] || [ -z "${PR_FILES}" ]; then
    # An empty file list may be a transient forge data race. Issue #2093
    # found empty results correlated with recent merge-commit updates and
    # hypothesized asynchronous diff computation, but the exact mechanism
    # is not an established forge API contract. Retry once before refusing
    # to approve, so we don't fail a genuinely non-empty PR.
    echo "::notice::PR files came back empty; retrying once in case of a transient forge data race (forge_get_pr_files)" >&2
    sleep 10
    if PR_FILES=$(forge_get_pr_files); then
      PR_FILES_FETCH_FAILED=false
    else
      PR_FILES_FETCH_FAILED=true
      PR_FILES=""
    fi
  fi
  if [ "${PR_FILES_FETCH_FAILED}" = true ] || [ -z "${PR_FILES}" ]; then
    echo "::error::Failed to fetch PR files or PR has no changed files — refusing to approve (forge_get_pr_files)" >&2
    exit 1
  fi

  if [[ ${#REVIEW_ACTIVE_PROTECTED_PATHS[@]} -gt 0 ]]; then
    PROTECTED_MATCHES=""
    while IFS= read -r file; do
      [ -z "${file}" ] && continue
      for pattern in "${REVIEW_ACTIVE_PROTECTED_PATHS[@]}"; do
        if [[ "${file}" == "${pattern}"* ]]; then
          PROTECTED_MATCHES="${PROTECTED_MATCHES}${file}"$'\n'
          break
        fi
      done
    done <<< "${PR_FILES}"

    if [ -n "${PROTECTED_MATCHES}" ]; then
      echo "PR touches protected paths — downgrading approve to comment"
      echo "${PROTECTED_MATCHES}" | sed '/^$/d' | sed 's/^/  /'

      PROTECTED_NOTICE=$'\n\n---\n\n'
      PROTECTED_NOTICE+=$'> **Protected paths detected** — this PR modifies files under one or more\n'
      PROTECTED_NOTICE+=$'> protected paths. The review agent cannot approve PRs that touch these paths.\n'
      PROTECTED_NOTICE+=$'> A human reviewer must approve this PR.\n'
      PROTECTED_NOTICE+=$'>\n'
      PROTECTED_NOTICE+=$'> Protected files in this PR:\n'
      while IFS= read -r f; do
        [ -z "${f}" ] && continue
        PROTECTED_NOTICE+="> - \`${f}\`"$'\n'
      done <<< "${PROTECTED_MATCHES}"

      # Rewrite the result file with downgraded action and appended notice.
      MODIFIED_RESULT=$(mktemp)
      CLEANUP_FILES+=("${MODIFIED_RESULT}")
      jq --arg notice "${PROTECTED_NOTICE}" \
        '.action = "comment" | .body = (.body + $notice)' \
        "${RESULT_FILE}" > "${MODIFIED_RESULT}"
      RESULT_FILE="${MODIFIED_RESULT}"
      DOWNGRADED=true
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Label-actions validation: the review agent may recommend contextual labels
# (e.g. area/api, priority/high). Validate them here so the label reason
# appears in the review body. Actual label API calls happen after posting.
# ---------------------------------------------------------------------------
REVIEW_CONTROL_LABELS=(
  "ready-for-merge" "requires-manual-review" "rejected"
  "ready-for-review" "fullsend-no-fix" "fullsend-fix"
)

is_control_label() {
  local label="$1"
  for cl in "${REVIEW_CONTROL_LABELS[@]}"; do
    if [[ "${cl}" == "${label}" ]]; then
      return 0
    fi
  done
  # Pipeline-managed label prefixes
  if [[ "${label}" == risk/* ]]; then
    return 0
  fi
  return 1
}

remove_stale_risk_labels() {
  local keep="${1:-}"
  for stale_risk in "risk/low" "risk/moderate" "risk/elevated" "risk/high" "risk/critical"; do
    [[ -n "${keep}" && "risk/${keep}" == "${stale_risk}" ]] && continue
    forge_remove_label_edit "${stale_risk}"
  done
}

VALIDATED_LABEL_ADDS=()
VALIDATED_LABEL_REMOVES=()
LABEL_REASON=""

HAS_LABEL_ACTIONS=$(jq 'has("label_actions")' "${RESULT_FILE}")
if [[ "${HAS_LABEL_ACTIONS}" == "true" ]]; then
  LABEL_REASON=$(jq -r '.label_actions.reason' "${RESULT_FILE}")
  LABEL_COUNT=$(jq '.label_actions.actions | length' "${RESULT_FILE}")

  echo "Validating ${LABEL_COUNT} label action(s)..."

  # Fetch existing repo labels once.
  EXISTING_LABELS=$(forge_list_repo_labels)

  label_exists() {
    local label="$1"
    echo "${EXISTING_LABELS}" | grep -qFx "${label}"
  }

  for i in $(seq 0 $((LABEL_COUNT - 1))); do
    LA_ACTION=$(jq -r ".label_actions.actions[${i}].action" "${RESULT_FILE}")
    LA_LABEL=$(jq -r ".label_actions.actions[${i}].label" "${RESULT_FILE}")

    # Sanitize jq -r output: strip newlines, carriage returns, and GHA
    # workflow command delimiters to prevent command injection via crafted
    # label names or action values.
    LA_ACTION="${LA_ACTION//$'\n'/}"
    LA_ACTION="${LA_ACTION//$'\r'/}"
    LA_ACTION="${LA_ACTION//::/:}"
    LA_LABEL="${LA_LABEL//$'\n'/}"
    LA_LABEL="${LA_LABEL//$'\r'/}"
    LA_LABEL="${LA_LABEL//::/:}"

    if [[ ! "${LA_LABEL}" =~ ^[a-zA-Z0-9._/:\ +\-]+$ ]]; then
      echo "::warning::Refused label '${LA_LABEL}' -- contains invalid characters"
      continue
    fi

    if is_control_label "${LA_LABEL}"; then
      echo "::warning::Refused to ${LA_ACTION} control label '${LA_LABEL}' -- control labels are managed by the review pipeline"
      continue
    fi

    case "${LA_ACTION}" in
      add)
        if ! label_exists "${LA_LABEL}"; then
          echo "::warning::Skipping label '${LA_LABEL}' -- does not exist in repo (will not auto-create)"
          continue
        fi
        VALIDATED_LABEL_ADDS+=("${LA_LABEL}")
        ;;
      remove)
        VALIDATED_LABEL_REMOVES+=("${LA_LABEL}")
        ;;
      *)
        echo "::warning::Unknown label action '${LA_ACTION}' for label '${LA_LABEL}'"
        ;;
    esac
  done

  # Append label reason to body if any labels validated.
  VALIDATED_COUNT=$(( ${#VALIDATED_LABEL_ADDS[@]} + ${#VALIDATED_LABEL_REMOVES[@]} ))
  if [[ "${VALIDATED_COUNT}" -gt 0 ]]; then
    LABEL_NOTICE=$'\n\n---\n'"**Labels:** ${LABEL_REASON}"
    LABEL_MODIFIED_RESULT=$(mktemp)
    CLEANUP_FILES+=("${LABEL_MODIFIED_RESULT}")
    jq --arg notice "${LABEL_NOTICE}" \
      '.body = (.body + $notice)' \
      "${RESULT_FILE}" > "${LABEL_MODIFIED_RESULT}"
    RESULT_FILE="${LABEL_MODIFIED_RESULT}"
  fi
fi

# ---------------------------------------------------------------------------
# Append action-hints footer (request-changes only)
# ---------------------------------------------------------------------------

if [ "${ACTION}" = "request-changes" ]; then
  ACTION_HINTS_FOOTER=$'\n\n---\n**Next steps:**\n- `/fs-fix` — agent addresses review findings automatically\n- `/fs-fix <your instruction>` — agent fixes with your specific guidance\n- Push commits directly — review re-runs automatically on push\n- `/fs-fix-stop` — disable automatic fix runs for this PR'
  FOOTER_RESULT=$(mktemp)
  CLEANUP_FILES+=("${FOOTER_RESULT}")
  jq --arg footer "${ACTION_HINTS_FOOTER}" \
    '.body = (.body + $footer)' \
    "${RESULT_FILE}" > "${FOOTER_RESULT}"
  RESULT_FILE="${FOOTER_RESULT}"
fi

# ---------------------------------------------------------------------------
# Risk assessment: apply risk/* label and post breakdown comment.
# Risk level is informational only — it does not gate the review outcome.
# Applied BEFORE forge_post_review so labels land even when the review
# submission fails (e.g. 422 self-review in eval environments).
# Label logic is mirrored in post-review-test.sh — update both.
# ---------------------------------------------------------------------------
HAS_RISK=$(jq 'has("risk_assessment")' "${RESULT_FILE}")
if [[ "${HAS_RISK}" == "true" ]]; then
  RISK_LEVEL=$(jq -r '.risk_assessment.level' "${RESULT_FILE}")
  RISK_SCORE=$(jq -r '.risk_assessment.score' "${RESULT_FILE}")

  # Validate score is an integer 1-5.  Do NOT interpolate the raw value
  # into the workflow command — it failed validation and may contain
  # control sequences.
  if [[ ! "${RISK_SCORE}" =~ ^[1-5]$ ]]; then
    echo "::warning::Invalid risk score, defaulting to level-only"
    RISK_SCORE="?"
  fi

  # Sanitize level value (same pattern as lines 108-116)
  RISK_LEVEL="${RISK_LEVEL//$'\n'/}"
  RISK_LEVEL="${RISK_LEVEL//$'\r'/}"
  RISK_LEVEL="${RISK_LEVEL//%/}"
  RISK_LEVEL="${RISK_LEVEL//:/}"

  case "${RISK_LEVEL}" in
    low|moderate|elevated|high|critical) ;;
    *)
      echo "::warning::Invalid risk level '${RISK_LEVEL}', skipping risk label"
      RISK_LEVEL=""
      ;;
  esac

  if [[ -n "${RISK_LEVEL}" ]]; then
    remove_stale_risk_labels "${RISK_LEVEL}"

    # Label color by level
    case "${RISK_LEVEL}" in
      low)      RISK_COLOR="0E8A16" ;;
      moderate) RISK_COLOR="FBCA04" ;;
      elevated) RISK_COLOR="E4A221" ;;
      high)     RISK_COLOR="D93F0B" ;;
      critical) RISK_COLOR="B60205" ;;
    esac

    echo "Applying risk/${RISK_LEVEL} label"
    forge_create_label "risk/${RISK_LEVEL}" "PR risk: ${RISK_LEVEL}" "${RISK_COLOR}"
    forge_add_label_edit "risk/${RISK_LEVEL}"

    # Post sticky risk comment
    RISK_RATIONALE=$(jq -r '(.risk_assessment.rationale // "No rationale provided.")[0:2000]' "${RESULT_FILE}" \
      | sed 's/<[^>]*>//g; s/!\[[^]]*\]([^)]*)//g; s/\[\([^]]*\)\]([^)]*)/\1/g; s/|/\\|/g')

    RISK_COMMENT=$(jq -n \
      --arg score "${RISK_SCORE}" \
      --arg level "${RISK_LEVEL}" \
      --arg rationale "${RISK_RATIONALE}" \
      -r '"<!-- fullsend:risk-assessment -->\n**Risk Assessment: \($level) (\($score)/5)**\n\n<details>\n<summary>Details</summary>\n\n\($rationale)\n\n</details>"')

    printf '%s' "${RISK_COMMENT}" | fullsend post-comment \
      --repo "${REPO}" \
      --number "${PR_NUMBER}" \
      --marker "<!-- fullsend:risk-assessment -->" \
      --token "${REVIEW_TOKEN}" \
      --result - >/dev/null 2>&1 || echo "::warning::Failed to post risk comment"
  else
    remove_stale_risk_labels
  fi
else
  remove_stale_risk_labels
fi

# ---------------------------------------------------------------------------
# Post the review. Exit code 10 = stale-head: the PR HEAD moved after the
# agent reviewed it. When this happens, post a /fs-review comment to
# re-dispatch a fresh review for the current HEAD.
# ---------------------------------------------------------------------------
POST_REVIEW_EXIT=0
forge_post_review "${RESULT_FILE}" || POST_REVIEW_EXIT=$?

if [ "${POST_REVIEW_EXIT}" -eq 10 ]; then
  echo "Stale-head detected — checking whether to re-dispatch review"

  # Loop guard: if a stale-head re-dispatch comment was posted recently
  # (within the last 5 minutes), skip to avoid cascading dispatches from
  # rapid force-pushes. The next synchronize event will pick it up.
  REDISPATCH_MARKER="<!-- fullsend:stale-head-redispatch -->"
  RECENT_REDISPATCH=$(forge_get_recent_redispatch_comments "${REDISPATCH_MARKER}" 300) || RECENT_REDISPATCH=0

  if [ "${RECENT_REDISPATCH}" -gt 0 ]; then
    echo "Recent stale-head re-dispatch already exists — skipping"
  else
    echo "Re-dispatching review for current HEAD"
    forge_post_comment "/fs-review
${REDISPATCH_MARKER}" || echo "::warning::Failed to post re-dispatch comment"
  fi

  # Stale-head is handled gracefully — exit 0 so the workflow does not
  # appear as a failure.
  exit 0
elif [ "${POST_REVIEW_EXIT}" -ne 0 ]; then
  echo "::error::fullsend post-review failed with exit code ${POST_REVIEW_EXIT} (PR #${PR_NUMBER} in ${REPO})" >&2
  exit "${POST_REVIEW_EXIT}"
fi

# ---------------------------------------------------------------------------
# Outcome labels: apply labels based on the review action.
# Labels are created if missing, matching the needs-human pattern in
# post-fix.sh.
# Label logic is mirrored in post-review-test.sh — update both.
# ---------------------------------------------------------------------------

# When approve is downgraded due to protected paths, a human may already
# have approved the current HEAD. If the forge reports the PR as approved
# AND an authorized (write-level, non-bot, non-author) human approved this
# SHA, the protected-path requirement is already satisfied. Fail closed on
# any API error. Drafts never take this path.
HAS_HUMAN_APPROVAL=false
if [ "${ACTION}" = "approve" ] && [ "${DOWNGRADED}" = "true" ] && [ "${PR_IS_DRAFT}" != "true" ]; then
  echo "Protected-path downgrade — checking for existing authorized human approval"
  if forge_has_authorized_human_approval; then
    HAS_HUMAN_APPROVAL=true
    echo "Authorized human approval on current HEAD satisfies protected-path requirement"
  else
    echo "No authorized human approval on current HEAD — requires-manual-review"
  fi
fi

# Determine the target outcome label before mutating anything so we can
# skip no-op remove/re-add cycles that generate timeline noise.
OUTCOME_LABEL=""
if [ "${ACTION}" = "approve" ] && [ "${PR_IS_DRAFT}" != "true" ] && \
   { [ "${DOWNGRADED}" = "false" ] || [ "${HAS_HUMAN_APPROVAL}" = "true" ]; }; then
  OUTCOME_LABEL="ready-for-merge"
elif { [ "${ACTION}" = "approve" ] && { [ "${DOWNGRADED}" = "true" ] || [ "${PR_IS_DRAFT}" = "true" ]; }; } || \
     [ "${ACTION}" = "comment" ]; then
  OUTCOME_LABEL="requires-manual-review"
elif [ "${ACTION}" = "reject" ]; then
  OUTCOME_LABEL="rejected"
fi

# Remove stale outcome labels from prior runs, skipping the label we are
# about to apply so we don't create a pointless unlabel/relabel cycle.
# 2>/dev/null is intentional: removal of a non-existent label is the
# common case and not worth logging.
for stale_label in "ready-for-merge" "requires-manual-review" "rejected"; do
  [ "${stale_label}" = "${OUTCOME_LABEL}" ] && continue
  forge_remove_label_edit "${stale_label}"
done

if [ "${OUTCOME_LABEL}" = "ready-for-merge" ]; then
  if [ "${HAS_HUMAN_APPROVAL}" = "true" ]; then
    echo "Protected-path requirement satisfied by authorized human approval — applying ready-for-merge"
  else
    echo "Approve disposition — applying ready-for-merge label"
  fi
  forge_create_label "ready-for-merge" "All reviewers approved — ready to merge" "0E8A16"
  forge_add_label_edit "ready-for-merge"
elif [ "${OUTCOME_LABEL}" = "requires-manual-review" ]; then
  if [ "${PR_IS_DRAFT}" = "true" ] && [ "${ACTION}" = "approve" ]; then
    echo "PR is a draft — skipping ready-for-merge, applying requires-manual-review"
  else
    echo "Review requires human judgment — applying requires-manual-review label"
  fi
  forge_create_label "requires-manual-review" "Review requires human judgment" "FBCA04"
  forge_add_label_edit "requires-manual-review"
elif [ "${OUTCOME_LABEL}" = "rejected" ]; then
  echo "Reject disposition — closing PR and applying label"
  forge_create_label "rejected" "Approach rejected by review agent" "B60205"
  forge_close_pr "Closed by review agent: approach rejected."
  forge_add_label_edit "rejected"
elif [ "${ACTION}" = "request-changes" ]; then
  echo "Request-changes disposition — no outcome label (fix agent triggers on event)"
fi

# ---------------------------------------------------------------------------
# Contextual labels: apply validated label mutations from label_actions.
# ---------------------------------------------------------------------------
for label in "${VALIDATED_LABEL_ADDS[@]}"; do
  echo "Adding contextual label '${label}'..."
  forge_add_label "${label}"
done

for label in "${VALIDATED_LABEL_REMOVES[@]}"; do
  echo "Removing contextual label '${label}'..."
  forge_remove_label "${label}"
done

echo "Review posted on ${REPO}#${PR_NUMBER}"
