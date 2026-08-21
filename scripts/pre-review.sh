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
  GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json files --jq '.files[].path'
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
# Controlled by REVIEW_GIT_FETCH_DEPTH: "0" = full unshallow, unset = no-op.
# ---------------------------------------------------------------------------
if [[ "${REVIEW_GIT_FETCH_DEPTH:-}" == "0" ]]; then
  _TARGET_DIR="${REPO_DIR:-${GITHUB_WORKSPACE:-.}/target-repo}"
  if [[ ! -d "${_TARGET_DIR}" ]]; then
    echo "::warning::Clone-deepening skipped — target directory '${_TARGET_DIR}' not found"
  elif git -C "${_TARGET_DIR}" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
    echo "Deepening shallow clone for git history analysis..."
    if [[ "${FULLSEND_FORGE}" == "github" && -n "${GH_TOKEN:-}" && -n "${REPO_FULL_NAME:-}" ]]; then
      git -C "${_TARGET_DIR}" fetch --unshallow \
        "https://x-access-token:${GH_TOKEN}@github.com/${REPO_FULL_NAME}.git" 2>/dev/null \
        && echo "Clone deepened successfully" \
        || echo "::warning::Failed to deepen clone — Tier 2 risk signals may be degraded"
    elif [[ "${FULLSEND_FORGE}" == "gitlab" && -n "${REPO_FULL_NAME:-}" ]]; then
      _gl_token="${REVIEW_TOKEN:-${CI_JOB_TOKEN:-}}"
      if [[ -n "${REVIEW_TOKEN:-}" ]]; then
        _gl_user="oauth2"
      else
        _gl_user="gitlab-ci-token"
      fi
      _gl_host="${GITLAB_HOST:-}"
      if [[ -z "${_gl_host}" && -n "${PR_URL:-}" ]]; then
        _gl_host=$(echo "${PR_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
      fi
      if [[ -n "${_gl_token}" && -n "${_gl_host}" ]]; then
        git -C "${_TARGET_DIR}" fetch --unshallow \
          "https://${_gl_user}:${_gl_token}@${_gl_host}/${REPO_FULL_NAME}.git" 2>/dev/null \
          && echo "Clone deepened successfully" \
          || echo "::warning::Failed to deepen clone — Tier 2 risk signals may be degraded"
      else
        echo "::warning::Cannot deepen clone — missing GitLab credentials (REVIEW_TOKEN or CI_JOB_TOKEN) or host"
      fi
    else
      echo "::warning::Cannot deepen clone — missing credentials or unsupported forge"
    fi
  fi
fi

echo "PR #${PR_NUMBER} is open — proceeding with review agent"
