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
#   1 — error (review not posted, fallback comment posted, or the agent
#       result's action was explicitly "failure" — even though the failure
#       notice itself was published successfully, the review did not
#       complete, so the task outcome must not report Success)
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

# --- Review threads ---

# Select GitHub review-thread node IDs that are safe to auto-resolve.
# Reads a JSON array of reviewThreads.nodes from stdin; prints one ID per line.
#
# A thread is eligible when all of the following hold:
#   - still unresolved
#   - the viewer can resolve it
#   - the thread is outdated (the diff position no longer exists)
#   - every fetched comment is outdated and authored by the viewer
#     (human / other-bot comments are left alone, even if outdated)
#   - there is at least one comment
#   - comment pagination is complete — an incomplete page might hide a
#     human comment, so skip rather than guess
_select_outdated_review_thread_ids() {
  jq -r '
    .[]
    | select(.id != null)
    | select(.isResolved == false)
    | select(.viewerCanResolve == true)
    | select(.isOutdated == true)
    | select((.comments.pageInfo.hasNextPage // false) == false)
    | select((.comments.nodes // [] | length) > 0)
    | select(.comments.nodes // [] | all(.outdated == true))
    | select(.comments.nodes // [] | all(.viewerDidAuthor == true))
    | .id
  '
}

# Resolve still-open review threads whose only comments are outdated
# inline comments authored by this token (the review agent). Best-effort:
# fetch or mutation failures log a warning and return success so they
# cannot block posting the new review.
forge_resolve_outdated_review_threads() {
  local owner name query mutation
  local cursor has_next page response page_nodes nodes_json ids
  local id resolved failed
  local -a gh_args

  owner="${REPO%%/*}"
  name="${REPO##*/}"
  cursor=""
  has_next="true"
  page=0
  nodes_json="[]"
  resolved=0
  failed=0

  query='query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            isOutdated
            viewerCanResolve
            comments(first: 100) {
              pageInfo { hasNextPage }
              nodes {
                outdated
                viewerDidAuthor
              }
            }
          }
        }
      }
    }
  }'

  mutation='mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { isResolved }
    }
  }'

  while [[ "${has_next}" == "true" ]]; do
    page=$((page + 1))
    if [[ "${page}" -gt 20 ]]; then
      echo "::warning::Review thread pagination hit page cap — remaining threads skipped"
      break
    fi

    gh_args=(api graphql
      -f owner="${owner}"
      -f name="${name}"
      -F number="${PR_NUMBER}"
      -f query="${query}")
    if [[ -n "${cursor}" ]]; then
      gh_args+=(-f cursor="${cursor}")
    fi

    if ! response=$(GH_TOKEN="${REVIEW_TOKEN}" gh "${gh_args[@]}" 2>/dev/null); then
      echo "::warning::Failed to fetch review threads — skipping outdated-thread resolution"
      return 0
    fi

    if echo "${response}" | jq -e '.errors | type == "array" and length > 0' >/dev/null 2>&1; then
      echo "::warning::Review thread query returned errors — skipping outdated-thread resolution"
      return 0
    fi

    page_nodes=$(echo "${response}" | jq -c '.data.repository.pullRequest.reviewThreads.nodes // []' 2>/dev/null) || {
      echo "::warning::Failed to parse review threads — skipping outdated-thread resolution"
      return 0
    }
    nodes_json=$(jq -c --argjson page "${page_nodes}" '. + $page' <<< "${nodes_json}" 2>/dev/null) || {
      echo "::warning::Failed to merge review thread pages — skipping outdated-thread resolution"
      return 0
    }

    has_next=$(echo "${response}" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null) || has_next="false"
    cursor=$(echo "${response}" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' 2>/dev/null) || cursor=""
    if [[ "${has_next}" == "true" && -z "${cursor}" ]]; then
      echo "::warning::Review thread page missing cursor — stopping pagination"
      break
    fi
  done

  ids=$(echo "${nodes_json}" | _select_outdated_review_thread_ids 2>/dev/null) || ids=""
  if [[ -z "${ids}" ]]; then
    return 0
  fi

  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue
    if GH_TOKEN="${REVIEW_TOKEN}" gh api graphql \
      -f threadId="${id}" \
      -f query="${mutation}" >/dev/null 2>&1; then
      resolved=$((resolved + 1))
    else
      failed=$((failed + 1))
      echo "::warning::Failed to resolve review thread $(_gha_sanitize "${id}")"
    fi
  done <<< "${ids}"

  if [[ "${resolved}" -gt 0 ]]; then
    echo "Resolved ${resolved} outdated review-agent thread(s)"
  fi
  if [[ "${failed}" -gt 0 ]]; then
    echo "::warning::Failed to resolve ${failed} outdated review thread(s)"
  fi
  return 0
}

# --- Human dismissals ---

# Print a JSON array of resolved review threads that can stand as a human
# dismissal of a prior finding: resolved by a user who is not the PR author
# and holds write, maintain, or admin on the repository. Bots and logins
# that cannot be checked are never eligible. Each entry carries the thread
# path and lines, whether the review agent itself commented in it, and any
# finding ids stamped in the agent's comments (`finding:f_…` markers), so
# the caller can match a thread to a ledger entry. Prints [] when nothing qualifies or any lookup fails: a dismissal
# the runner cannot verify stays open.
forge_get_human_dismissals() {
  local owner name query cursor has_next page response page_nodes nodes_json
  local pr_author login role candidates eligible
  local -a gh_args

  owner="${REPO%%/*}"
  name="${REPO##*/}"
  cursor=""
  has_next="true"
  page=0
  nodes_json="[]"

  # The author exclusion is only as good as the author lookup: without a
  # known author nothing can be verified.
  pr_author="$(forge_get_pr_author)"
  if [[ -z "${pr_author}" ]]; then
    echo "::warning::Could not determine the PR author — human dismissals cannot be verified" >&2
    echo '[]'
    return 0
  fi

  query='query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            isResolved
            path
            line
            originalLine
            resolvedBy { login }
            comments(first: 100) {
              pageInfo { hasNextPage }
              nodes { body viewerDidAuthor }
            }
          }
        }
      }
    }
  }'

  while [[ "${has_next}" == "true" ]]; do
    page=$((page + 1))
    if [[ "${page}" -gt 20 ]]; then
      echo "::warning::Review thread pagination hit page cap — remaining threads not checked for dismissals" >&2
      break
    fi

    gh_args=(api graphql
      -f owner="${owner}"
      -f name="${name}"
      -F number="${PR_NUMBER}"
      -f query="${query}")
    if [[ -n "${cursor}" ]]; then
      gh_args+=(-f cursor="${cursor}")
    fi

    if ! response=$(GH_TOKEN="${REVIEW_TOKEN}" gh "${gh_args[@]}" 2>/dev/null); then
      echo "::warning::Failed to fetch review threads — human dismissals cannot be verified" >&2
      echo '[]'
      return 0
    fi
    if echo "${response}" | jq -e '.errors | type == "array" and length > 0' >/dev/null 2>&1; then
      echo "::warning::Review thread query returned errors — human dismissals cannot be verified" >&2
      echo '[]'
      return 0
    fi
    page_nodes=$(echo "${response}" | jq -c '.data.repository.pullRequest.reviewThreads.nodes // []' 2>/dev/null) || {
      echo '[]'
      return 0
    }
    nodes_json=$(jq -c --argjson page "${page_nodes}" '. + $page' <<< "${nodes_json}" 2>/dev/null) || {
      echo '[]'
      return 0
    }
    has_next=$(echo "${response}" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null) || has_next="false"
    cursor=$(echo "${response}" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' 2>/dev/null) || cursor=""
    if [[ "${has_next}" == "true" && -z "${cursor}" ]]; then
      break
    fi
  done

  # Resolved threads with a known resolver and complete comment pages. A
  # finding id stamp counts only in a comment this token authored (the
  # review agent's own), never in a reply anyone else wrote.
  candidates=$(jq -c '
    [ .[]
      | select(type == "object")
      | select(.isResolved == true)
      | select((.resolvedBy.login // "") != "")
      | select((.comments.pageInfo.hasNextPage // false) == false)
      | {
          path: .path,
          line: .line,
          original_line: .originalLine,
          resolved_by: .resolvedBy.login,
          agent_authored: ([ (.comments.nodes // [])[] | select(.viewerDidAuthor == true) ] | length > 0),
          ids: ([ (.comments.nodes // [])[] | select(.viewerDidAuthor == true) | .body // "" | scan("finding:(f_[A-Za-z0-9]+)") | .[0] ] | unique)
        }
    ]' <<< "${nodes_json}" 2>/dev/null) || candidates="[]"

  # Eligibility: not the PR author, a plain user login, and write or above
  # on the repository. One permission lookup per distinct resolver.
  eligible="[]"
  while IFS= read -r login; do
    [[ -z "${login}" ]] && continue
    [[ "${login,,}" == "${pr_author,,}" ]] && continue
    [[ "${login}" =~ ^[A-Za-z0-9-]+$ ]] || continue
    role=$(GH_TOKEN="${REVIEW_TOKEN}" gh api "repos/${REPO}/collaborators/${login}/permission" \
      --jq '.role_name' 2>/dev/null) || role=""
    case "${role}" in
      admin|maintain|write) eligible=$(jq -c --arg l "${login}" '. + [$l]' <<< "${eligible}") ;;
      *) ;;
    esac
  done < <(jq -r '[.[].resolved_by] | unique | .[]' <<< "${candidates}" 2>/dev/null)

  jq -c --argjson eligible "${eligible}" '[ .[] | select(.resolved_by as $l | $eligible | index($l) != null) ]' <<< "${candidates}" 2>/dev/null || echo '[]'
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

# GitHub-only: GitLab discussions have no isOutdated equivalent in this
# issue's scope. No-op so post-review can call this unconditionally.
forge_resolve_outdated_review_threads() {
  return 0
}

# --- Labels ---

# Human dismissals need a resolved thread from a reviewer the runner can
# vouch for. That check is not implemented for GitLab discussions, so no
# dismissal is verified here and a dismissed_by_human disposition stays open.
forge_get_human_dismissals() {
  echo '[]'
}

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

# Resolve still-open GitHub review threads whose only comments are
# outdated inline comments authored by the review agent. A later push
# marks those threads isOutdated; leaving them unresolved keeps them
# in the PR's unresolved-review state. Best-effort (GitLab no-op).
forge_resolve_outdated_review_threads

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
# The severity filter below can drop an info-level sub-agent-failure. Keep the
# unfiltered result so the projection still sees every failed dimension.
UNFILTERED_RESULT_FILE="${RESULT_FILE}"

# Assign ids on the unfiltered result so the ledger can keep a
# reclassified row the severity filter later drops from the posted review.
# ---------------------------------------------------------------------------
# Finding ledger: stable ids and dispositions.
#
# Every finding carries an opaque id (f_ plus random hex). On a re-review the
# prior ledger arrives as PRIOR_REVIEW_FILE, the JSON pre-review validated.
# A prior id is OPEN when its last disposition is absent, open, or
# reclassified, and CLOSED when it is resolved_by_change or
# dismissed_by_human. Open ids must be answered by this review; closed ids
# are carried forward unchanged, anchor and all, so a later review can
# recognise the same finding and not raise it again. Nothing is dropped for
# being outside the latest diff. Ids are never derived from the path or text.
# ---------------------------------------------------------------------------
PRIOR_JSON='{"findings":[]}'
if [[ -n "${PRIOR_REVIEW_FILE:-}" && -f "${PRIOR_REVIEW_FILE}" ]]; then
  if parsed_prior="$(jq -ce 'select(type == "object" and (.findings | type) == "array")' "${PRIOR_REVIEW_FILE}" 2>/dev/null)"; then
    PRIOR_JSON="${parsed_prior}"
  fi
fi
# Mint one 16-hex-char id per current and prior finding (at least 128) from
# /dev/urandom so the pool can never run dry and abort the post.
FINDING_COUNT="$(jq '.findings | if type == "array" then length else 0 end' "${RESULT_FILE}" 2>/dev/null || echo 0)"
PRIOR_COUNT="$(jq '.findings | length' <<< "${PRIOR_JSON}")"
MINT_COUNT=128
if [[ "${FINDING_COUNT}" =~ ^[0-9]+$ && "${PRIOR_COUNT}" =~ ^[0-9]+$ ]] && (( FINDING_COUNT + PRIOR_COUNT > MINT_COUNT )); then
  MINT_COUNT=$(( FINDING_COUNT + PRIOR_COUNT ))
fi
MINT_IDS="$(
  od -An -N"$((MINT_COUNT * 8))" -tx1 /dev/urandom | tr -d ' \n' | fold -w16 | head -n "${MINT_COUNT}" | sed 's/^/f_/' \
    | jq -R . | jq -sc .
)"

# Prior ledger: give legacy prior findings (written before ids existed) an id
# so they enter the ledger instead of vanishing, and split prior ids into
# open and closed. Minted ids used here are removed from the pool below.
PRIOR_LEDGER="$(jq -c --argjson mints "${MINT_IDS}" '
  def valid_id: type == "string" and test("^f_[A-Za-z0-9]+$");
  def closed_status: IN("resolved_by_change", "dismissed_by_human");
  ([ (.dispositions // [])[] | select(type == "object" and (.id | valid_id) and (.status | type == "string")) ]) as $disp
  | (reduce (.findings // [])[] as $f ({findings: [], mint_i: 0};
      if ($f.id | valid_id) then .findings += [$f]
      else .findings += [$f + {id: $mints[.mint_i]}] | .mint_i += 1
      end
    )) as $r
  | ($r.findings) as $fs
  | {
      findings: $fs,
      closed: [ $fs[] | .id as $id | ($disp | map(select(.id == $id)) | last) as $d
                | select($d != null and ($d.status | closed_status)) | . + {status: $d.status} ],
      open_ids: [ $fs[] | .id as $id | ($disp | map(select(.id == $id)) | last) as $d
                  | select($d == null or ($d.status | closed_status | not)) | .id ],
      used_mints: $r.mint_i
    }
' <<< "${PRIOR_JSON}")"
MINT_IDS="$(jq -c --argjson prior "${PRIOR_LEDGER}" '.[$prior.used_mints:]' <<< "${MINT_IDS}")"

# Id assignment for this review. A supplied id is kept only when it is an
# open prior id no earlier row already took and this review is not
# resolving; a closed, resolving, foreign, or duplicate id is replaced (a
# reclassified id must stay on its row, so it is kept). Without a usable id, copy the open prior id whose file and
# category match: the exact line first, else the only candidate at that
# place (a shifted line must not create a second ledger entry). Do not copy
# an id this review is closing. A missing file (null or N/A) is not a
# place, so those rows mint instead of inheriting. Otherwise mint.
# Supplied open ids of later rows are reserved for them.
if jq -e '.findings | type == "array"' "${RESULT_FILE}" >/dev/null 2>&1; then
  ID_RESULT="$(mktemp)"
  CLEANUP_FILES+=("${ID_RESULT}")
  jq --argjson prior "${PRIOR_LEDGER}" --argjson mints "${MINT_IDS}" '
    def valid_id: type == "string" and test("^f_[A-Za-z0-9]+$");
    def anchor_line: if type == "number" then . else null end;
    def anchor_file: if . == "N/A" or . == null then null else . end;
    def closed_status: IN("resolved_by_change", "dismissed_by_human");
    def resolving:
      (.status | closed_status)
      and (.rationale | type == "string" and length > 0)
      and (.evidence | type == "string" and length > 0);
    def reclassified:
      .status == "reclassified"
      and (.rationale | type == "string" and length > 0)
      and (.evidence | type == "string" and length > 0);
    ($prior.open_ids) as $open
    | ([ (.dispositions // [])[] | select(resolving or reclassified) | .id | select(valid_id) ]) as $closing
    | ([ (.dispositions // [])[] | select(resolving) | .id | select(valid_id) ]) as $resolving_ids
    | ([ $prior.findings[] | select(.id as $pid | $open | index($pid) != null) ]) as $open_findings
    | (.findings // []) as $rows
    | .findings = (
        reduce range(0; ($rows | length)) as $i (
          {done: [], mint_i: 0};
          . as $state
          | $rows[$i] as $f
          | ([ $state.done[].id ]) as $taken
          | (
              if ($f.id | valid_id) and ($open | index($f.id)) != null and ($taken | index($f.id)) == null
                 and ($resolving_ids | index($f.id)) == null
              then {id: $f.id, mint_i: $state.mint_i}
              else
                ([ $rows[($i + 1):][] | .id | select(valid_id) | select(. as $x | $open | index($x) != null) ]) as $reserved
                | ([ $open_findings[]
                     | select(.id as $pid | ($taken + $reserved + $closing) | index($pid) == null)
                     | select((.file | anchor_file) != null and ($f.file | anchor_file) != null)
                     | select((.file | anchor_file) == ($f.file | anchor_file) and .category == $f.category)
                   ]) as $same_place
                | ([ $same_place[] | select((.line | anchor_line) == ($f.line | anchor_line)) ]) as $exact
                | if ($exact | length) == 1 then {id: $exact[0].id, mint_i: $state.mint_i}
                  elif ($same_place | length) == 1 then {id: $same_place[0].id, mint_i: $state.mint_i}
                  elif ($mints[$state.mint_i] | valid_id | not) then error("ran out of finding ids")
                  else {id: $mints[$state.mint_i], mint_i: ($state.mint_i + 1)}
                  end
              end
            ) as $picked
          | .done += [$f + {id: $picked.id}]
          | .mint_i = $picked.mint_i
        )
        | .done
      )
  ' "${RESULT_FILE}" > "${ID_RESULT}"
  mv "${ID_RESULT}" "${RESULT_FILE}"
fi


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
# Risk verdict gate: when risk assessment is enabled, downgrade approve to
# comment if the risk score exceeds the threshold, the score is missing,
# or the assessment is degraded. Runs after protected-path check so both
# notices are appended when both gates trigger. The threshold is coerced
# to a number via --argjson for safe numeric comparison (--arg creates a
# string that compares as false with numbers in jq).
# ---------------------------------------------------------------------------
REVIEW_RISK_ASSESSMENT_ENABLED_RAW="${REVIEW_RISK_ASSESSMENT_ENABLED:-}"
if [[ "${REVIEW_RISK_ASSESSMENT_ENABLED_RAW}" =~ [[:cntrl:]] ]]; then
  echo "::error::REVIEW_RISK_ASSESSMENT_ENABLED contains control characters (only printable ASCII allowed)"
  exit 1
fi
case "${REVIEW_RISK_ASSESSMENT_ENABLED_RAW}" in
  true) ;;
  false) echo "Risk assessment disabled (REVIEW_RISK_ASSESSMENT_ENABLED=false)" ;;
  "") ;;
  *)
    SAFE_ENABLED=$(printf '%s' "${REVIEW_RISK_ASSESSMENT_ENABLED_RAW}" | tr -dc '[:print:]')
    SAFE_ENABLED="${SAFE_ENABLED//::/}"
    SAFE_ENABLED="${SAFE_ENABLED//%/%25}"
    echo "::error::REVIEW_RISK_ASSESSMENT_ENABLED='${SAFE_ENABLED}' is unrecognized (expected 'true' or 'false')"
    exit 1
  ;;
esac
if [ "${REVIEW_RISK_ASSESSMENT_ENABLED_RAW}" = "true" ]; then
  THRESHOLD="${REVIEW_RISK_VERDICT_THRESHOLD:-4}"
  # Validate threshold is an integer 1-6; 6 disables the gate entirely (opt-out)
  if [[ ! "${THRESHOLD}" =~ ^[1-6]$ ]]; then
    SAFE_THRESHOLD=$(printf '%s' "${THRESHOLD}" | tr -dc '[:print:]')
    SAFE_THRESHOLD="${SAFE_THRESHOLD//::/}"
    SAFE_THRESHOLD="${SAFE_THRESHOLD//%/%25}"
    echo "::error::REVIEW_RISK_VERDICT_THRESHOLD='${SAFE_THRESHOLD}' is invalid (expected integer 1-6)"
    exit 1
  fi

  HAS_RISK_ASSESSMENT=$(jq 'has("risk_assessment")' "${RESULT_FILE}")

  # Defense-in-depth: normalize structurally invalid risk_assessment to
  # absent. The harness validation_loop (review-result.schema.json) runs
  # before this post-script executes, so well-formed pipelines reject
  # malformed assessments during validation. This block guards against
  # direct script invocation (tests, debugging) and future schema changes
  # that might relax the risk_assessment constraint.
  if [ "${HAS_RISK_ASSESSMENT}" = "true" ]; then
    RISK_STRUCT_VALID=$(jq '
      .risk_assessment | type == "object"
      and has("score") and (.score | type == "number" and floor == . and . >= 1 and . <= 5)
      and has("level") and (.level | type == "string")
      and has("rationale") and (.rationale | type == "string")
    ' "${RESULT_FILE}")
    if [ "${RISK_STRUCT_VALID}" != "true" ]; then
      echo "::warning::risk_assessment is structurally invalid — normalizing to absent for fail-closed handling"
      NORMALIZED_RESULT=$(mktemp)
      CLEANUP_FILES+=("${NORMALIZED_RESULT}")
      jq 'del(.risk_assessment)' "${RESULT_FILE}" > "${NORMALIZED_RESULT}"
      RESULT_FILE="${NORMALIZED_RESULT}"
      HAS_RISK_ASSESSMENT="false"
    fi
  fi

  # Threshold=6 disables the verdict gate entirely (informational scoring only).
  # Missing, degraded, invalid, and high scores all pass through as-is when
  # disabled — risk labels and comments still apply but do not gate the verdict.
  if [ "${THRESHOLD}" = "6" ]; then
    echo "Risk verdict gate disabled (REVIEW_RISK_VERDICT_THRESHOLD=6) — informational scoring only"
  else
    # -----------------------------------------------------------------------
    # Evaluate risk status once — shared between approve and comment actions.
    # -----------------------------------------------------------------------
    RISK_STATUS="ok"
    RISK_NOTICE=""

    if [ "${HAS_RISK_ASSESSMENT}" != "true" ]; then
      RISK_STATUS="missing"
      RISK_NOTICE=$'\n\n---\n\n'
      RISK_NOTICE+=$'> **Risk assessment missing** — risk assessment is enabled but no score was\n'
      RISK_NOTICE+=$'> produced. A human reviewer must evaluate this PR.\n'
    else
      RISK_HAS_DEGRADED=$(jq '.risk_assessment | has("degraded")' "${RESULT_FILE}")
      RISK_HAS_SCORE=$(jq '.risk_assessment | has("score")' "${RESULT_FILE}")

      if [ "${RISK_HAS_DEGRADED}" = "true" ]; then
        RISK_DEGRADED_REASON=$(jq -r '.risk_assessment.degraded' "${RESULT_FILE}" | tr -dc '[:print:]')
        RISK_STATUS="degraded"
        RISK_NOTICE=$'\n\n---\n\n'
        RISK_NOTICE+=$'> **Risk assessment degraded** — the risk score was not fully computed\n'
        RISK_NOTICE+="> (${RISK_DEGRADED_REASON}). A human reviewer must evaluate this PR."$'\n'
      elif [ "${RISK_HAS_SCORE}" != "true" ]; then
        RISK_STATUS="missing_score"
        RISK_NOTICE=$'\n\n---\n\n'
        RISK_NOTICE+=$'> **Risk score missing** — risk assessment is present but contains no\n'
        RISK_NOTICE+=$'> score. A human reviewer must evaluate this PR.\n'
      else
        # Validate score type in jq to prevent bash $(jq -r) re-canonicalization:
        # strings ("1\n"), arrays, objects, null, booleans, and floats (1.5) are
        # all rejected before they reach bash. Only integer numbers 1–5 pass.
        SCORE_VALID=$(jq '.risk_assessment | has("score") and (.score | type == "number" and floor == . and . >= 1 and . <= 5)' "${RESULT_FILE}")
        if [ "${SCORE_VALID}" != "true" ]; then
          RISK_STATUS="invalid"
          echo "::warning::Risk assessment score is invalid (expected integer 1-5)"
          RISK_NOTICE=$'\n\n---\n\n'
          RISK_NOTICE+="> **Risk score invalid** — the risk assessment produced an invalid"$'\n'
          RISK_NOTICE+=$'> score. A human reviewer must evaluate this PR.\n'
        else
          RISK_SCORE=$(jq -r '.risk_assessment.score' "${RESULT_FILE}")
          THRESHOLD_CHECK=$(jq -n --argjson score "${RISK_SCORE}" --argjson threshold "${THRESHOLD}" '$score >= $threshold')
          if [ "${THRESHOLD_CHECK}" = "true" ]; then
            RISK_STATUS="high"
            RISK_NOTICE=$'\n\n---\n\n'
            RISK_NOTICE+="> **Risk score ${RISK_SCORE}/5** — this PR has a risk score at or above the"$'\n'
            RISK_NOTICE+="> threshold (${THRESHOLD}). Automatic approval is not permitted for high-risk PRs."$'\n'
            RISK_NOTICE+=$'> A human reviewer must evaluate this PR.\n'
          fi
        fi
      fi
    fi

    # Apply risk gate or notice based on action
    if [ -n "${RISK_NOTICE}" ]; then
      if [ "${ACTION}" = "approve" ]; then
        echo "Risk gate triggered (${RISK_STATUS}) — downgrading approve to comment"
        RISK_MODIFIED_RESULT=$(mktemp)
        CLEANUP_FILES+=("${RISK_MODIFIED_RESULT}")
        jq --arg notice "${RISK_NOTICE}" \
          '.action = "comment" | .risk_gated = true | .body = (.body + $notice)' \
          "${RESULT_FILE}" > "${RISK_MODIFIED_RESULT}"
        RESULT_FILE="${RISK_MODIFIED_RESULT}"
        DOWNGRADED=true
      elif [ "${ACTION}" = "comment" ]; then
        echo "Agent chose comment — appending risk notice (${RISK_STATUS}) to review body"
        COMMENT_MODIFIED=$(mktemp)
        CLEANUP_FILES+=("${COMMENT_MODIFIED}")
        jq --arg notice "${RISK_NOTICE}" \
          '.body = (.body + $notice)' \
          "${RESULT_FILE}" > "${COMMENT_MODIFIED}"
        RESULT_FILE="${COMMENT_MODIFIED}"
      fi
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

    # Decide on the values as given; print only _gha_sanitize copies.
    LA_ACTION_SHOWN=$(_gha_sanitize "${LA_ACTION}")
    LA_LABEL_SHOWN=$(_gha_sanitize "${LA_LABEL}")

    if [[ "${LA_LABEL}" == *::* || ! "${LA_LABEL}" =~ ^[a-zA-Z0-9._/:\ +\-]+$ ]]; then
      echo "::warning::Refused label '${LA_LABEL_SHOWN}' -- contains invalid characters or a double colon"
      continue
    fi

    if is_control_label "${LA_LABEL}"; then
      echo "::warning::Refused to ${LA_ACTION_SHOWN} control label '${LA_LABEL}' -- control labels are managed by the review pipeline"
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
        echo "::warning::Unknown label action '${LA_ACTION_SHOWN}' for label '${LA_LABEL}'"
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
# Risk level gates the review outcome when REVIEW_RISK_ASSESSMENT_ENABLED
# is true (see risk verdict gate above). Labels are applied regardless so
# the risk level is visible even when the gate downgrades the verdict.
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


# Human dismissals are the runner's to verify, not the model's to assert:
# a dismissed_by_human disposition counts only against a resolved review
# thread from an eligible reviewer (not the PR author, write or above).
# Fetched once, and only when the model used that status.
HUMAN_DISMISSALS='[]'
if jq -e '[.dispositions[]? | select(type == "object" and .status == "dismissed_by_human")] | length > 0' "${RESULT_FILE}" >/dev/null 2>&1; then
  HUMAN_DISMISSALS="$(forge_get_human_dismissals)" || HUMAN_DISMISSALS='[]'
  if ! jq -e 'type == "array"' <<< "${HUMAN_DISMISSALS}" >/dev/null 2>&1; then
    HUMAN_DISMISSALS='[]'
  fi
fi

# Ledger accounting. Each open prior id gets one effective status, decided
# here and used by both the approval guard and the projection:
#   resolved_by_change  — rationale and evidence given.
#   reclassified        — rationale and evidence given, and this review
#                         re-emits a finding with the same id (at its new
#                         severity or category, below threshold or not).
#                         Without that finding the id stays open: nothing
#                         else carries the new classification.
#   dismissed_by_human  — rationale and evidence given, the prior finding is
#                         not high or critical, and a verified dismissal
#                         thread matches it: by stamped id, or an unstamped
#                         thread at the one open finding's file and line.
#   open                — everything else, including a disposition aimed at
#                         a closed id (a human dismissal or a recorded fix is
#                         not the model's to undo).
# A prior high or critical id still open blocks an approval unless this
# review re-emits it at high or critical: absent, or re-emitted lower with
# no supported reclassification, is not a fix.
LEDGER_REPORT="$(jq -c --argjson prior "${PRIOR_LEDGER}" --argjson dismissals "${HUMAN_DISMISSALS}" --slurpfile unfiltered "${UNFILTERED_RESULT_FILE}" '
  def valid_id: type == "string" and test("^f_[A-Za-z0-9]+$");
  def nonempty: type == "string" and length > 0;
  def well_formed_disposition:
    type == "object"
    and (.id | valid_id)
    and (.status | IN("open", "resolved_by_change", "reclassified", "dismissed_by_human"))
    and (.rationale | type == "string")
    and (.evidence | type == "string");
  def supported: (.rationale | nonempty) and (.evidence | nonempty);
  def dismissal_verified($f):
    # A thread stamped with finding ids binds only to those ids. An
    # unstamped thread the review agent commented in binds by file and
    # line, and only when exactly one open prior finding sits there. A
    # thread with no agent comment is not about any finding.
    any($dismissals[]?;
      if ((.ids // []) | length) > 0 then (.ids | index($f.id) != null)
      else (.agent_authored == true)
        and (.path | type == "string") and .path == $f.file
        and ($f.line | type == "number")
        and (.line == $f.line or .original_line == $f.line)
        and ([ $prior.findings[]
               | select(.id as $pid | $prior.open_ids | index($pid) != null)
               | select(.file == $f.file and .line == $f.line) ] | length) == 1
      end);
  ($prior.open_ids) as $open
  | ([ $prior.closed[].id ]) as $closed
  | ([ (.dispositions // [])[] | select(well_formed_disposition) ]) as $given
  | ([ ($unfiltered[0].findings // [])[] | .id | select(valid_id) ]) as $current_ids
  | ([
      $open[]
      | . as $id
      | (($prior.findings | map(select(.id == $id)) | first) // {id: $id}) as $f
      | ($given | map(select(.id == $id)) | last) as $got
      | if $got == null then {id: $id, status: "open", why: "unanswered"}
        elif $got.status == "resolved_by_change" and ($got | supported) then {id: $id, status: "resolved_by_change"}
        elif $got.status == "reclassified" and ($got | supported) then
          if ($current_ids | index($id)) != null then {id: $id, status: "reclassified"}
          else {id: $id, status: "open", why: "reclassified-without-finding"} end
        elif $got.status == "dismissed_by_human" and ($got | supported) then
          if ($f.severity | IN("high", "critical")) then {id: $id, status: "open", why: "dismissed-high"}
          elif dismissal_verified($f) then {id: $id, status: "dismissed_by_human"}
          else {id: $id, status: "open", why: "dismissed-unverified"} end
        else {id: $id, status: "open"}
        end
    ]) as $effective
  | ([ $effective[] | select(.status == "open") | .id ]) as $still_open
  | {
      effective: [ $effective[] | {id, status} ],
      unanswered: [ $effective[] | select(.why == "unanswered") | .id ],
      reclassified_without_finding: [ $effective[] | select(.why == "reclassified-without-finding") | .id ],
      dismissed_high: [ $effective[] | select(.why == "dismissed-high") | .id ],
      dismissed_unverified: [ $effective[] | select(.why == "dismissed-unverified") | .id ],
      blocking: [ $prior.findings[]
                  | select(.severity | IN("high", "critical"))
                  | select(.id as $id | $still_open | index($id) != null)
                  | .id ],
      ignored_closed: [ (.dispositions // [])[] | select(type == "object") | .id
                        | select(type == "string") | select(. as $id | $closed | index($id) != null) ] | unique
    }
' "${RESULT_FILE}")"
LEDGER_EFFECTIVE="$(jq -c '.effective' <<< "${LEDGER_REPORT}")"
UNANSWERED_IDS="$(jq -r '.unanswered | join(", ")' <<< "${LEDGER_REPORT}")"
if [[ -n "${UNANSWERED_IDS}" ]]; then
  echo "::warning::No disposition recorded for prior finding id(s) ${UNANSWERED_IDS}; recorded as open"
fi
RECLASSIFIED_WITHOUT_FINDING_IDS="$(jq -r '.reclassified_without_finding | join(", ")' <<< "${LEDGER_REPORT}")"
if [[ -n "${RECLASSIFIED_WITHOUT_FINDING_IDS}" ]]; then
  echo "::warning::Reclassified prior finding id(s) ${RECLASSIFIED_WITHOUT_FINDING_IDS} have no current finding with that id; recorded as open"
fi
DISMISSED_HIGH_IDS="$(jq -r '.dismissed_high | join(", ")' <<< "${LEDGER_REPORT}")"
if [[ -n "${DISMISSED_HIGH_IDS}" ]]; then
  echo "::warning::dismissed_by_human is not accepted for high or critical prior finding id(s) ${DISMISSED_HIGH_IDS}; recorded as open"
fi
DISMISSED_UNVERIFIED_IDS="$(jq -r '.dismissed_unverified | join(", ")' <<< "${LEDGER_REPORT}")"
if [[ -n "${DISMISSED_UNVERIFIED_IDS}" ]]; then
  echo "::warning::No resolved review thread from an eligible reviewer matches dismissed prior finding id(s) ${DISMISSED_UNVERIFIED_IDS}; recorded as open"
fi
IGNORED_CLOSED_IDS="$(jq -r '.ignored_closed | join(", ")' <<< "${LEDGER_REPORT}")"
if [[ -n "${IGNORED_CLOSED_IDS}" ]]; then
  echo "::warning::Ignoring disposition for closed prior finding id(s) ${IGNORED_CLOSED_IDS}; a resolved or human-dismissed finding stays closed"
fi
BLOCKING_IDS="$(jq -r '.blocking | join(", ")' <<< "${LEDGER_REPORT}")"
if [[ -n "${BLOCKING_IDS}" && "${ACTION}" = "approve" ]]; then
  echo "::warning::Approval withheld: prior high/critical finding id(s) ${BLOCKING_IDS} are still open"
  LEDGER_NOTICE=$'\n\n> **Note:** Approval withheld. Earlier high or critical finding(s) '"${BLOCKING_IDS}"$' are still open.'
  LEDGER_RESULT="$(mktemp)"
  CLEANUP_FILES+=("${LEDGER_RESULT}")
  jq --arg notice "${LEDGER_NOTICE}" \
    '.action = "comment" | .body = (.body + $notice)' \
    "${RESULT_FILE}" > "${LEDGER_RESULT}"
  RESULT_FILE="${LEDGER_RESULT}"
  ACTION="comment"
  DOWNGRADED=true
fi

# Append a machine-readable projection only when every schema-validated finding
# can be represented safely. A lossy projection could turn a failed sub-agent
# into an apparently clean dimension on the next re-review. Low-severity
# challenger failures are non-dimensional and retain the pre-challenger findings.
# A dimension failure the severity filter removed (Sonnet-tier failures are
# recorded at info) must still suppress the projection.
#
# The projection is the ledger: every current finding plus every prior
# finding not re-emitted, each with its id, and one {id, status} per prior
# id. A prior id whose disposition stays open keeps its prior severity and
# category; only a supported reclassification changes them. Closed
# findings keep their anchor so the next review can recognise
# them; the oldest closed entries are dropped past 100. Rationale and
# evidence stay in the human-readable comment and never enter the marker.
PRIOR_FINDINGS_PROJECTION="$(jq -c --slurpfile unfiltered "${UNFILTERED_RESULT_FILE}" --argjson prior "${PRIOR_LEDGER}" --argjson effective "${LEDGER_EFFECTIVE}" '
  def allowed_category:
    IN(
      "logic-error", "nil-deref", "off-by-one", "edge-case", "api-contract", "missing-test", "test-inadequate", "pattern-violation", "test-weakened", "test-removed", "mock-loosened", "assertion-weakened", "coverage-reduced", "test-poisoning", "split-payload", "stale-reference",
      "auth-bypass", "rbac-violation", "data-exposure", "privilege-escalation", "injection-vuln", "sandbox-escape", "xss", "ssrf", "insecure-deserialization", "prompt-injection", "unicode-steganography", "bidi-override", "homoglyph-attack", "instruction-smuggling", "fail-open", "permission-expansion", "permission-reduction", "role-escalation", "workflow-permission", "secret-exposure",
      "scope-exceeded", "tier-mismatch", "unauthorized-change", "scope-creep", "missing-authorization", "misleading-label", "design-direction", "complexity-ratio", "misplaced-abstraction", "architectural-conflict", "design-smell", "over-engineering", "under-engineering",
      "naming-convention", "error-handling-idiom", "api-shape", "code-organization", "doc-style", "pattern-inconsistency",
      "stale-doc", "missing-doc", "incorrect-doc", "incomplete-doc",
      "breaking-api", "breaking-schema", "breaking-config", "breaking-cli", "missing-deprecation", "missing-version-bump", "backward-incompatible",
      "uxd-evaluate-design-heuristics"
    );
  def safe_path:
    type == "string" and length > 0 and . != "N/A" and
    test("^[ -~]+$") and
    (test("(^/|/$|//|(^|/)\\.\\.?(/|$)|[\\\\\\r\\n<>])") | not);
  def non_dimensional_category:
    type == "string" and IN(
      "protected-path", "provenance-warning", "scope-authorization-implicit"
    );
  def non_dimensional_finding:
    (.category | non_dimensional_category) or
    (.category == "sub-agent-failure" and .severity == "low");
  def projectable:
    (.category | type == "string" and allowed_category) and (.file == "N/A" or (.file | safe_path));
  def closed_status: IN("resolved_by_change", "dismissed_by_human");
  def project_finding:
    {
      severity,
      category,
      file: (if .file == "N/A" then null else .file end),
      id
    } + (if (.line | type) == "number" then {line} else {} end);
  def is_closed($accounted; $id):
    [$accounted[] | select(.id == $id and (.status | closed_status))] | length > 0;
  (.findings // []) as $findings
  | ($findings | map(select(non_dimensional_finding | not))) as $dimension_findings
  | (($unfiltered[0].findings // [])
      | any(.[]; .category == "sub-agent-failure" and (non_dimensional_finding | not))) as $dimension_failed
  | (($unfiltered[0].findings // []) | map(select((non_dimensional_finding | not) and projectable))) as $ledger_findings
  | if (.action | IN("approve", "request-changes", "comment", "reject"))
      and ($dimension_findings | all(.[]; projectable))
      and ($dimension_failed | not) then
      ($effective) as $answered
      | ([ $prior.closed[] | {id, status} ]) as $carried
      | ($answered + $carried) as $accounted
      | ([ $ledger_findings[] | select(is_closed($accounted; .id) | not)
           | . as $row
           | (($prior.findings | map(select(.id == $row.id)) | first) // null) as $p
           | (($answered | map(select(.id == $row.id)) | first) // null) as $a
           | if $p != null and $a != null and $a.status == "open"
             then $row + {severity: $p.severity, category: $p.category} else $row end
           | project_finding ]) as $current
      | ([ $current[].id ]) as $current_ids
      | ([ $prior.findings[] | select(.id as $id | $current_ids | index($id) == null) | project_finding ]) as $carried_findings
      | ([ $carried_findings[] | select(is_closed($accounted; .id) | not) ]) as $carried_open
      | ([ $prior.closed[] | select(.id as $id | $current_ids | index($id) == null) | project_finding ]) as $older_closed
      | ([ $carried_findings[] | select(is_closed($accounted; .id)) | select(.id as $id | [$prior.closed[].id] | index($id) == null) ]) as $newly_closed
      | ($older_closed + $newly_closed | if length > 100 then .[(length - 100):] else . end) as $carried_closed
      | ([ $carried_closed[].id ]) as $kept_closed
      | {
          version: 2,
          findings: ($current + $carried_open + $carried_closed)
        }
        + (if ($accounted | length) > 0 then
             {dispositions: [ $accounted[] | select((.status | closed_status | not) or (.id as $id | $kept_closed | index($id) != null)) ]}
           else {} end)
    else empty
    end
' "${RESULT_FILE}")"
PROJECTION_MARKER=""
if [[ -n "${PRIOR_FINDINGS_PROJECTION}" ]]; then
  PRIOR_FINDINGS_ENCODED="$(printf '%s' "${PRIOR_FINDINGS_PROJECTION}" | base64 | tr -d '\n')"
  PROJECTION_MARKER="<!-- fullsend:review-findings-v2:${PRIOR_FINDINGS_ENCODED} -->"
fi
TMP_RESULT="$(mktemp)"
CLEANUP_FILES+=("${TMP_RESULT}")
jq --arg marker "${PROJECTION_MARKER}" '
  # pre-review ends the current section at the first line containing a
  # history delimiter, so any copy in the agent body would hide the marker.
  def strip_reserved:
    gsub("(?m)^<!-- fullsend:review-findings-v[12]:[A-Za-z0-9+/=]+ -->\\r?$"; "")
    | gsub("<!-- sticky:history-(start|end) -->"; "")
    | gsub("(?m)^<summary>Previous run( \\([0-9]+\\))?</summary>\\r?$"; "");
  # Removing a substring can join its neighbours into a new reserved string,
  # so repeat until nothing changes. Each changing pass shortens the body.
  def strip_reserved_fixpoint:
    . as $in | strip_reserved | if . == $in then . else strip_reserved_fixpoint end;
  .body = (
    if (.body | type) == "string" then .body else "" end
    | strip_reserved_fixpoint
  )
  # The marker leads the body: sticky truncation cuts from the end, so a
  # very long review must never lose its ledger.
  | if $marker == "" then . else .body = ($marker + "\n\n" + .body) end
' \
  "${RESULT_FILE}" > "${TMP_RESULT}"
mv "${TMP_RESULT}" "${RESULT_FILE}"

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

# Determine the target outcome label before mutating anything so we can
# skip no-op remove/re-add cycles that generate timeline noise. An explicit
# failure result (handled below) gets no outcome label, so OUTCOME_LABEL
# stays empty in that case — which correctly removes all three stale
# labels in the loop that follows.
OUTCOME_LABEL=""
if [ "${ACTION}" = "approve" ] && [ "${DOWNGRADED}" = "false" ] && [ "${PR_IS_DRAFT}" != "true" ]; then
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
#
# This must run before the action=failure exit below: a PR can carry a
# stale ready-for-merge/requires-manual-review/rejected label from an
# earlier run whose review did complete, and a failed run must not leave
# that stale label in place (#1612).
for stale_label in "ready-for-merge" "requires-manual-review" "rejected"; do
  [ "${stale_label}" = "${OUTCOME_LABEL}" ] && continue
  forge_remove_label_edit "${stale_label}"
done

# ---------------------------------------------------------------------------
# Explicit failure result: the agent could not complete a real review (e.g.
# tool-failure, missing-context). forge_post_review above already published
# the failure notice successfully — that is publication success, not review
# success. Without this check the script falls through to the success exit
# at the bottom, so the runner reports Success for a review that never
# happened. Propagate a failed task outcome instead. (#1612)
# ---------------------------------------------------------------------------
if [ "${ACTION}" = "failure" ]; then
  FAILURE_REASON=$(jq -r '.reason // "unknown"' "${RESULT_FILE}")
  echo "::error::Review result reported action=failure (reason: ${FAILURE_REASON}) — failure notice was published, but propagating a failed task outcome (PR #${PR_NUMBER} in ${REPO})" >&2
  exit 1
fi

if [ "${OUTCOME_LABEL}" = "ready-for-merge" ]; then
  echo "Approve disposition — applying ready-for-merge label"
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
