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
      # Detect a failed Tier 2 clone-deepen attempt independently of what the
      # sub-agent reported. REVIEW_GIT_FETCH_DEPTH is not forwarded to the
      # sandbox, so the sub-agent cannot reliably tell "skipped" (deepening
      # never attempted) from "degraded" (deepening attempted and failed)
      # and may omit `degraded` even when the repo is still shallow. Mirror
      # the unset-only default from pre-review.src.sh:177-179 (a `+set`
      # check, not `:-`) so an explicitly empty REVIEW_GIT_FETCH_DEPTH="" —
      # which also skips deepening on the pre-script side — does not get
      # coerced to "0" here and falsely treated as a failed deepen. An
      # explicit non-zero value means deepening was never attempted, which
      # is the existing "skipped" behaviour; check the same checkout path
      # pre-review.src.sh:182 uses.
      TIER2_DEEPEN_FAILED=false
      if [ "${REVIEW_GIT_FETCH_DEPTH-0}" = "0" ]; then
        RISK_TARGET_DIR="${REPO_DIR:-${GITHUB_WORKSPACE:-.}/target-repo}"
        if [ -d "${RISK_TARGET_DIR}" ]; then
          RISK_SHALLOW_STATUS=0
          RISK_SHALLOW_OUTPUT=$(git -C "${RISK_TARGET_DIR}" rev-parse --is-shallow-repository 2>/dev/null) || RISK_SHALLOW_STATUS=$?
          # The only result that proves full history is available is exit 0
          # with output exactly "false". Treat anything else — a non-zero
          # exit, or output that isn't exactly "false" (including "true" or
          # unexpected/empty output) — as a failed/unknown deepen so history
          # availability fails closed instead of silently approving.
          if [ "${RISK_SHALLOW_STATUS}" -ne 0 ] || [ "${RISK_SHALLOW_OUTPUT}" != "false" ]; then
            TIER2_DEEPEN_FAILED=true
          fi
        fi
      fi

      RISK_HAS_DEGRADED=$(jq '.risk_assessment | has("degraded")' "${RESULT_FILE}")
      RISK_HAS_SCORE=$(jq '.risk_assessment | has("score")' "${RESULT_FILE}")

      if [ "${TIER2_DEEPEN_FAILED}" = "true" ]; then
        RISK_STATUS="degraded"
        RISK_NOTICE=$'\n\n---\n\n'
        RISK_NOTICE+=$'> **Risk assessment degraded** — the risk score was not fully computed\n'
        RISK_NOTICE+="> (tier2-deepen-failed). A human reviewer must evaluate this PR."$'\n'
      elif [ "${RISK_HAS_DEGRADED}" = "true" ]; then
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

# Append a machine-readable projection only when every schema-validated finding
# can be represented safely. A lossy projection could turn a failed sub-agent
# into an apparently clean dimension on the next re-review. Low-severity
# challenger failures are non-dimensional and retain the pre-challenger findings.
# A dimension failure the severity filter removed (Sonnet-tier failures are
# recorded at info) must still suppress the projection.
PRIOR_FINDINGS_PROJECTION="$(jq -c --slurpfile unfiltered "${UNFILTERED_RESULT_FILE}" '
  def allowed_category:
    IN(
      "logic-error", "nil-deref", "off-by-one", "edge-case", "api-contract", "missing-test", "test-inadequate", "pattern-violation", "test-weakened", "test-removed", "mock-loosened", "assertion-weakened", "coverage-reduced", "test-poisoning", "split-payload", "stale-reference",
      "auth-bypass", "rbac-violation", "data-exposure", "privilege-escalation", "injection-vuln", "sandbox-escape", "xss", "ssrf", "insecure-deserialization", "prompt-injection", "unicode-steganography", "bidi-override", "homoglyph-attack", "instruction-smuggling", "fail-open", "permission-expansion", "permission-reduction", "role-escalation", "workflow-permission", "secret-exposure",
      "scope-exceeded", "tier-mismatch", "unauthorized-change", "scope-creep", "missing-authorization", "misleading-label", "design-direction", "complexity-ratio", "misplaced-abstraction", "architectural-conflict", "design-smell", "over-engineering", "under-engineering",
      "naming-convention", "error-handling-idiom", "api-shape", "code-organization", "doc-style", "pattern-inconsistency",
      "stale-doc", "missing-doc", "incorrect-doc", "incomplete-doc",
      "breaking-api", "breaking-schema", "breaking-config", "breaking-cli", "missing-deprecation", "missing-version-bump", "backward-incompatible"
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
  (.findings // []) as $findings
  | ($findings | map(select(non_dimensional_finding | not))) as $dimension_findings
  | (($unfiltered[0].findings // [])
      | any(.[]; .category == "sub-agent-failure" and (non_dimensional_finding | not))) as $dimension_failed
  | if (.action | IN("approve", "request-changes", "comment", "reject"))
      and ($dimension_findings | all(.[]; projectable))
      and ($dimension_failed | not) then
      {
        version: 2,
        findings: [
          $dimension_findings[]
          | {severity, category, file: (if .file == "N/A" then null else .file end)}
            + (if (.line | type) == "number" then {line} else {} end)
        ]
      }
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
  | if $marker == "" then . else .body = (.body + "\n\n" + $marker) end
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
