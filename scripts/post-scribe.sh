#!/usr/bin/env bash
# GENERATED from post-scribe.src.sh — DO NOT EDIT. Run: make script-build
# post-scribe.sh — Parse scribe agent JSON output, apply security gate,
# and write to the repository (comments on existing issues, new issues).
#
# Runs on the host after sandbox cleanup.
#
# Required env vars:
#   SCRIBE_REPO    — target repository (owner/name or group/project)
#   FULLSEND_FORGE — "github" or "gitlab"
#   SCRIBE_DRY_RUN — "true" to preview without writing (ALWAYS true during dev)
#
# Forge-specific token env vars:
#   GH_TOKEN       — GitHub token (when FULLSEND_FORGE=github)
#   GITLAB_TOKEN   — GitLab token (when FULLSEND_FORGE=gitlab)
#
# Jira issue creation (FULLSEND_TRACKER=jira): new issues are created in
# SCRIBE_JIRA_PROJECT; comments are not supported. See
# lib/jira-scribe-ops.lib.sh for the required JIRA_* variables.
#
# Optional env vars:
#   SCRIBE_MODE              — "all" (default), "comments_only", "new_issues_only"
#   SCRIBE_SLACK_WEBHOOK_URL — Slack incoming webhook for notification (skip if unset)
#
# SAFETY: This script REFUSES to run if SCRIBE_DRY_RUN is not explicitly set.
# This prevents accidental writes during development.

set -euo pipefail

: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scribe-ops.lib.sh
# BEGIN bundled: lib/scribe-ops.lib.sh
# shellcheck shell=bash
# scribe-ops.lib.sh — Forge-dispatch wrapper for scribe operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE. When
# FULLSEND_TRACKER=jira, additionally sources the Jira tracker ops, which
# redefine the backlog and issue-creation functions so they target Jira
# while repo context (closed issues, PRs, docs) stays on the forge.
# FULLSEND_TRACKER defaults to FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
SCRIBE_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-scribe-ops.lib.sh
# shellcheck shell=bash
# github-scribe-ops.lib.sh — GitHub forge operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected env vars:
#   SCRIBE_REPO  — GitHub repository (owner/name)
#   GH_TOKEN     — GitHub token with issues read/write scope

[[ -n "${GITHUB_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_SCRIBE_OPS_SH_LOADED=1

# --- Pre-script: repo context ---

# Fetch all open items from the issues endpoint (paginated). GitHub's REST
# /issues endpoint includes pull requests — callers filter them out.
forge_fetch_open_issues_raw() {
  local repo="$1" output_file="$2"
  gh api --paginate "repos/${repo}/issues?state=open&per_page=100" \
    > "${output_file}"
}

# Filter raw issues response into the backlog format: remove PRs, extract
# fields, truncate bodies to 500 chars.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq -s '[.[][] | select(.pull_request == null) | {number, title, body, labels, milestone, url: .html_url}]' "${raw_file}" \
    | jq '[.[] | .body = ((.body // "")[:500] + if ((.body // "") | length) > 500 then "…" else "" end)]' \
    > "${backlog_file}"
}

# Count total paginated items (issues + PRs on GitHub).
forge_count_paginated_total() {
  local raw_file="$1"
  jq -s '[.[][]] | length' "${raw_file}"
}

# Fetch recently closed issues.
forge_list_closed_issues() {
  local repo="$1" output_file="$2" limit="$3"
  gh issue list --repo "${repo}" --state closed \
    --json number,title,labels,url --limit "${limit}" \
    > "${output_file}"
}

# Fetch open pull requests. Normalizes output to include headRefName.
forge_list_open_prs() {
  local repo="$1" output_file="$2" limit="$3" token="$4"
  GH_TOKEN="${token}" gh pr list --repo "${repo}" --state open \
    --json number,title,labels,url,headRefName --limit "${limit}" \
    > "${output_file}"
}

# Get repo-level open_issues_count (includes PRs on GitHub) for truncation
# detection. Returns empty string on failure so callers can fall back.
forge_get_issue_count() {
  local repo="$1"
  gh api "repos/${repo}" --jq '.open_issues_count' 2>/dev/null || echo ""
}

# Fetch the repo's doc tree (markdown files under docs/).
forge_get_repo_tree() {
  local repo="$1" token="$2" output_file="$3"
  GH_TOKEN="${token}" gh api "repos/${repo}/git/trees/main?recursive=1" \
    --jq '[.tree[] | select(.path | startswith("docs/") and (.path | endswith(".md"))) | .path]' \
    > "${output_file}" 2>/dev/null || echo '[]' > "${output_file}"
}

# --- Post-script: issue/comment operations ---

# Fetch all comments on an issue (paginated). Returns a flat JSON array.
forge_list_issue_comments() {
  local repo="$1" issue_num="$2"
  gh api --paginate "repos/${repo}/issues/${issue_num}/comments" 2>/dev/null \
    | jq -s '[.[][] | {body}]'
}

# Post a comment on an issue. Body is read from stdin.
forge_post_issue_comment() {
  local repo="$1" issue_num="$2"
  gh issue comment "${issue_num}" --repo "${repo}" --body-file -
}

# Create a new issue with labels. Body is read from stdin. Returns the
# issue URL. Falls back to label-less creation if labels don't exist.
forge_create_issue() {
  local repo="$1" title="$2" labels="$3"
  local url body_file
  body_file=$(mktemp)
  cat > "${body_file}"
  url=$(gh issue create --repo "${repo}" --title "${title}" \
    --label "${labels}" --body-file "${body_file}" 2>/dev/null) || \
  url=$(gh issue create --repo "${repo}" --title "${title}" --body-file "${body_file}")
  rm -f "${body_file}"
  if [[ -z "${url}" ]]; then
    echo "ERROR: forge_create_issue: failed to create issue or missing URL in response" >&2
    return 1
  fi
  echo "${url}"
}

# Return the base URL for linking to issues.
forge_issue_url_base() {
  local repo="$1"
  echo "https://github.com/${repo}/issues"
}

# Return the CI run URL for notifications.
forge_run_url() {
  echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-${1}}/actions/runs/${GITHUB_RUN_ID:-0}"
}
# END bundled: lib/github-scribe-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-scribe-ops.lib.sh
# shellcheck shell=bash
# gitlab-scribe-ops.lib.sh — GitLab forge operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected env vars:
#   SCRIBE_REPO    — GitLab project path (group/project)
#   GITLAB_TOKEN   — GitLab personal/project access token
#   CI_SERVER_HOST — GitLab CI predefined variable (set by runner)
#   CI_SERVER_URL  — GitLab CI predefined variable; origin for API requests
#                    and links, including any non-default port (falls back
#                    to https://${CI_SERVER_HOST} when unset)

[[ -n "${GITLAB_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_SCRIBE_OPS_SH_LOADED=1

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
# Also derives the trusted origin (scheme, host, and optional port) from
# CI_SERVER_URL so self-managed instances on non-default HTTPS ports work.
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

# Prints the trusted GitLab origin (https://host[:port]) for API requests
# and generated links. Derived from CI_SERVER_URL, a GitLab CI predefined
# variable that carries any non-default port; falls back to
# https://${CI_SERVER_HOST} when CI_SERVER_URL is unset. Fails closed when
# the origin is not HTTPS or its host does not match CI_SERVER_HOST.
_gitlab_trusted_origin() {
  _validate_gitlab_host "${CI_SERVER_HOST:-}" || return 1
  local origin="${CI_SERVER_URL:-https://${CI_SERVER_HOST}}"
  if [[ ! "${origin}" =~ ^https://([a-zA-Z0-9._-]+)(:[0-9]+)?$ ]]; then
    echo "ERROR: CI_SERVER_URL is not an HTTPS origin (https://host[:port]): $(_gha_sanitize "${origin}")" >&2
    return 1
  fi
  local host="${BASH_REMATCH[1]}"
  _validate_gitlab_host "${host}" || return 1
  printf '%s\n' "${origin}"
}

# Validates an origin (https://host[:port]) parsed from an untrusted URL
# against the trusted CI server origin. Scheme, host, and port must all
# match: a URL without a port only matches a trusted origin without one.
_validate_gitlab_origin() {
  local origin="$1" trusted
  trusted=$(_gitlab_trusted_origin) || return 1
  if [[ "${origin,,}" != "${trusted,,}" ]]; then
    echo "ERROR: GitLab origin '$(_gha_sanitize "${origin}")' does not match CI server origin '$(_gha_sanitize "${trusted}")'" >&2
    return 1
  fi
}
# END bundled: lib/gitlab-host-validation.lib.sh

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  # Scribe has no input URL to cross-reference — uses the trusted CI origin.
  local origin
  origin=$(_gitlab_trusted_origin) || return 1
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "${origin}/api/v4${endpoint}" \
    "$@"
}

# Paginate a GitLab GET endpoint, collecting all pages into a single JSON
# array written to the given output file. Uses page-counter increment.
_gitlab_paginate() {
  local endpoint="$1" output_file="$2"
  local page=1 max_pages=100
  local tmp_file
  tmp_file=$(mktemp)
  echo '[]' > "${output_file}"
  while [[ "${page}" -le "${max_pages}" ]]; do
    local sep="?"
    [[ "${endpoint}" == *"?"* ]] && sep="&"
    local batch
    batch=$(_gitlab_api GET "${endpoint}${sep}per_page=100&page=${page}") || { echo "WARNING: _gitlab_paginate: API call failed on page ${page}" >&2; break; }
    local count
    count=$(echo "${batch}" | jq 'length') || break
    [[ "${count}" -eq 0 ]] && break
    jq -s 'add' "${output_file}" <(echo "${batch}") > "${tmp_file}"
    mv "${tmp_file}" "${output_file}"
    page=$((page + 1))
  done
  rm -f "${tmp_file}"
}

# --- Pre-script: repo context ---

# Fetch all open issues (paginated). GitLab's /issues endpoint does NOT
# include merge requests — no PR filtering needed. Output is saved as a
# flat JSON array matching the GitHub raw format for downstream processing.
forge_fetch_open_issues_raw() {
  local repo="$1" output_file="$2"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_paginate "/projects/${repo_encoded}/issues?state=opened&order_by=created_at&sort=desc" "${output_file}"
}

# Filter/normalize raw issues into the backlog format. GitLab fields are
# normalized to match the GitHub output schema: iid→number,
# description→body, web_url→url, labels (strings)→label objects.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq '[.[] | {
    number: .iid,
    title,
    body: (.description // ""),
    labels: [.labels[]? | {name: .}],
    milestone,
    url: .web_url
  } | .body = ((.body // "")[:500] + if ((.body // "") | length) > 500 then "…" else "" end)]' \
    "${raw_file}" > "${backlog_file}"
}

# Count total paginated items. On GitLab, the issues endpoint only returns
# issues (no MRs), so this equals the issue count.
forge_count_paginated_total() {
  local raw_file="$1"
  jq 'length' "${raw_file}"
}

# Fetch recently closed issues, normalized to common schema.
forge_list_closed_issues() {
  local repo="$1" output_file="$2" limit="$3"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api GET "/projects/${repo_encoded}/issues?state=closed&order_by=updated_at&sort=desc&per_page=${limit}" 2>/dev/null \
    | jq '[.[] | {
        number: .iid,
        title,
        labels: [.labels[]? | {name: .}],
        url: .web_url
      }]' > "${output_file}" || echo '[]' > "${output_file}"
}

# Fetch open merge requests, normalized to match the PR schema. The
# source_branch field is mapped to headRefName for forge-neutral agent use.
forge_list_open_prs() {
  local repo="$1" output_file="$2" limit="$3" _token="$4"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api GET "/projects/${repo_encoded}/merge_requests?state=opened&per_page=${limit}" 2>/dev/null \
    | jq '[.[] | {
        number: .iid,
        title,
        labels: [.labels[]? | {name: .}],
        url: .web_url,
        headRefName: .source_branch
      }]' > "${output_file}" || echo '[]' > "${output_file}"
}

# Get the project's open_issues_count (issues only on GitLab, no MRs).
forge_get_issue_count() {
  local repo="$1"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api GET "/projects/${repo_encoded}" 2>/dev/null \
    | jq '.open_issues_count // empty' 2>/dev/null || echo ""
}

# Fetch the repo's doc tree (markdown files under docs/).
forge_get_repo_tree() {
  local repo="$1" _token="$2" output_file="$3"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  local tmp_file
  tmp_file=$(mktemp)
  _gitlab_paginate "/projects/${repo_encoded}/repository/tree?recursive=true&ref=main" "${tmp_file}"
  jq '[.[] | select(.path | startswith("docs/") and (.path | endswith(".md"))) | .path]' \
    "${tmp_file}" > "${output_file}" 2>/dev/null || echo '[]' > "${output_file}"
  rm -f "${tmp_file}"
}

# --- Post-script: issue/comment operations ---

# Fetch all notes (comments) on an issue. Returns a flat JSON array
# with field projection to match the GitHub comments shape.
forge_list_issue_comments() {
  local repo="$1" issue_num="$2"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  local tmp_file
  tmp_file=$(mktemp)
  trap 'rm -f "${tmp_file}"' RETURN
  _gitlab_paginate "/projects/${repo_encoded}/issues/${issue_num}/notes?sort=asc" "${tmp_file}"
  jq '[.[] | select(.system != true) | {body}]' "${tmp_file}"
}

# Post a note (comment) on an issue. Body is read from stdin.
forge_post_issue_comment() {
  local repo="$1" issue_num="$2"
  local repo_encoded body_file rc=0
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  cat > "${body_file}"
  _gitlab_api POST "/projects/${repo_encoded}/issues/${issue_num}/notes" \
    --data-urlencode "body@${body_file}" > /dev/null || rc=$?
  rm -f "${body_file}"
  return "${rc}"
}

# Create a new issue with labels. Body is read from stdin. Returns the
# issue web URL.
forge_create_issue() {
  local repo="$1" title="$2" labels="$3"
  local repo_encoded body_file
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  cat > "${body_file}"
  local response
  response=$(_gitlab_api POST "/projects/${repo_encoded}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "labels=${labels}" \
    --data-urlencode "description@${body_file}" 2>/dev/null) || \
  response=$(_gitlab_api POST "/projects/${repo_encoded}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description@${body_file}")
  rm -f "${body_file}"
  local url
  url=$(echo "${response}" | jq -r '.web_url // empty')
  if [[ -z "${url}" ]]; then
    echo "ERROR: forge_create_issue: failed to create issue or missing web_url in response" >&2
    return 1
  fi
  echo "${url}"
}

# Return the base URL for linking to issues.
forge_issue_url_base() {
  local repo="$1" origin
  origin=$(_gitlab_trusted_origin) || return 1
  echo "${origin}/${repo}/-/issues"
}

# Return the CI run/job URL for notifications.
forge_run_url() {
  if [[ -n "${CI_JOB_URL:-}" ]]; then
    echo "${CI_JOB_URL}"
  else
    local origin
    origin=$(_gitlab_trusted_origin) || return 1
    echo "${origin}/${1}"
  fi
}
# END bundled: lib/gitlab-scribe-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '$(_gha_sanitize "${FULLSEND_FORGE:-}")' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac

FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE}}"

case "${FULLSEND_TRACKER}" in
  "${FULLSEND_FORGE}") ;;
  jira)
# BEGIN bundled: lib/jira-scribe-ops.lib.sh
# shellcheck shell=bash
# jira-scribe-ops.lib.sh — Jira Cloud tracker operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh, which
# sources this file AFTER the GitHub/GitLab forge library when
# FULLSEND_TRACKER=jira. The functions below redefine the backlog and write
# operations (open-issue fetch, backlog filter, open count, issue creation,
# issue URL base) so that backlog matching and writes target one Jira
# project, while repo context (closed issues, open PRs, doc index, run URL)
# keeps coming from the forge.
#
# Scope (MVP): new issues only, in one operator-configured project and
# issue type. Comment writes are not supported — existing_issue is a
# numeric forge issue number and Jira keys need a separate string-key path.
#
# All writes happen host-side in post-scribe.sh with operator-provided
# credentials; the sandbox never receives the Jira token.
#
# Jira Cloud only: JIRA_BASE_URL must be https://<site>.atlassian.net.
#
# Expected env vars:
#   JIRA_BASE_URL          — Jira Cloud base URL (https://<site>.atlassian.net)
#   JIRA_USER_EMAIL        — Jira account email for Basic auth
#   JIRA_TOKEN             — Jira Cloud API token
#   SCRIBE_JIRA_PROJECT    — Jira project key that backlog reads and new
#                            issues are scoped to (e.g. "PROJ")
#
# Optional env vars:
#   SCRIBE_JIRA_ISSUE_TYPE — issue type name for created issues (default: "Task")

[[ -n "${JIRA_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
JIRA_SCRIBE_OPS_SH_LOADED=1

: "${JIRA_USER_EMAIL:?JIRA_USER_EMAIL must be set}"
: "${JIRA_TOKEN:?JIRA_TOKEN must be set}"
: "${JIRA_BASE_URL:?JIRA_BASE_URL must be set}"
: "${SCRIBE_JIRA_PROJECT:?SCRIBE_JIRA_PROJECT must be set}"

while [[ "${JIRA_BASE_URL}" == */ ]]; do
  JIRA_BASE_URL="${JIRA_BASE_URL%/}"
done
if [[ ! "${JIRA_BASE_URL}" =~ ^https://[a-zA-Z0-9-]+\.atlassian\.net$ ]]; then
  echo "ERROR: JIRA_BASE_URL must be a Jira Cloud URL (https://<site>.atlassian.net)" >&2
  exit 1
fi
if [[ ! "${SCRIBE_JIRA_PROJECT}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
  echo "ERROR: SCRIBE_JIRA_PROJECT must be a Jira project key (e.g. PROJ)" >&2
  exit 1
fi
SCRIBE_JIRA_ISSUE_TYPE="${SCRIBE_JIRA_ISSUE_TYPE:-Task}"

# Maximum pages fetched per paginated Jira read (100 issues per JQL page).
SCRIBE_JIRA_MAX_PAGES="${SCRIBE_JIRA_MAX_PAGES:-50}"

_scribe_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    "${JIRA_BASE_URL}/rest/api/3${endpoint}" \
    "$@"
}

# Escape a value for use inside a double-quoted JQL string literal.
_scribe_jql_quote() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '"%s"' "${val}"
}

_scribe_jira_backlog_jql() {
  printf 'project = %s AND statusCategory != Done ORDER BY created DESC' \
    "$(_scribe_jql_quote "${SCRIBE_JIRA_PROJECT}")"
}

# Run a JQL search, following nextPageToken. Writes one JSON array of issues
# per page to output_file (same multi-document shape as `gh api --paginate`).
# Returns 2 if the page cap was hit while more results remained.
_scribe_jira_search_paginated() {
  local jql="$1" fields_json="$2" output_file="$3"
  local token="" page payload response is_last
  : > "${output_file}"
  for ((page = 1; page <= SCRIBE_JIRA_MAX_PAGES; page++)); do
    payload=$(jq -cn --arg jql "${jql}" --argjson fields "${fields_json}" --arg tok "${token}" \
      '{jql: $jql, fields: $fields, maxResults: 100} + (if $tok != "" then {nextPageToken: $tok} else {} end)')
    response=$(_scribe_jira_api POST "/search/jql" --data "${payload}") || {
      echo "ERROR: Jira JQL search failed" >&2
      return 1
    }
    # A 2xx response that is not JSON, or has no issues array, must not be
    # read as "no results" — callers use that to prove a duplicate is absent.
    if ! printf '%s' "${response}" | jq -ce 'select(type == "object" and (.issues | type) == "array") | .issues' >> "${output_file}"; then
      echo "ERROR: Jira JQL search returned a malformed or incomplete response" >&2
      return 1
    fi
    token=$(printf '%s' "${response}" | jq -r '.nextPageToken // empty') || {
      echo "ERROR: Jira JQL search response could not be parsed" >&2
      return 1
    }
    is_last=$(printf '%s' "${response}" | jq -r '.isLast // false') || {
      echo "ERROR: Jira JQL search response could not be parsed" >&2
      return 1
    }
    if [[ -z "${token}" ]] || [[ "${is_last}" == "true" ]]; then
      return 0
    fi
  done
  echo "WARNING: Jira search stopped after ${SCRIBE_JIRA_MAX_PAGES} pages; results are truncated" >&2
  return 2
}

# --- Pre-script: backlog ---

forge_fetch_open_issues_raw() {
  local _repo="$1" output_file="$2" rc=0
  _scribe_jira_search_paginated "$(_scribe_jira_backlog_jql)" \
    '["summary","description","labels","status"]' "${output_file}" || rc=$?
  # rc 2 (page cap) is reported by forge_get_issue_count's comparison.
  [[ ${rc} -eq 0 || ${rc} -eq 2 ]]
}

# Convert raw Jira issues to the backlog format. Jira issues carry a string
# `key` instead of a numeric `number`; the description (ADF) is flattened
# to plain text and truncated to 500 chars.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq -s --arg base "${JIRA_BASE_URL}" '[.[][] | {
      key,
      title: (.fields.summary // ""),
      body: ([.fields.description | .. | objects | select(.type == "text") | .text] | join(" ")),
      labels: (.fields.labels // []),
      url: ($base + "/browse/" + .key)
    }]' "${raw_file}" \
    | jq '[.[] | .body = (.body[:500] + if (.body | length) > 500 then "…" else "" end)]' \
    > "${backlog_file}"
}

forge_count_paginated_total() {
  local raw_file="$1"
  jq -s '[.[][]] | length' "${raw_file}"
}

# Approximate open-issue count for truncation detection. Returns empty on
# failure so callers fall back to the fetched count.
forge_get_issue_count() {
  local _repo="$1"
  _scribe_jira_api POST "/search/approximate-count" \
    --data "$(jq -cn --arg jql "$(_scribe_jira_backlog_jql)" '{jql: $jql}')" 2>/dev/null \
    | jq -r '.count // empty' 2>/dev/null || echo ""
}

# --- Post-script: issue operations ---

forge_list_issue_comments() {
  echo "ERROR: comments are not supported when FULLSEND_TRACKER=jira" >&2
  return 1
}

forge_post_issue_comment() {
  echo "ERROR: comments are not supported when FULLSEND_TRACKER=jira" >&2
  return 1
}

# Convert plain text to Atlassian Document Format. Blank lines split
# paragraphs; single newlines become hardBreak nodes.
_scribe_text_to_adf() {
  jq -Rsc '
    {
      type: "doc",
      version: 1,
      content: [
        split("\n\n")[]
        | (split("\n") | map(select(length > 0))) as $lines
        | select(($lines | length) > 0)
        | {type: "paragraph",
           content: ([$lines | to_entries[]
             | (if .key > 0 then [{type: "hardBreak"}] else [] end) + [{type: "text", text: .value}]]
             | add)}
      ]
    }'
}

# Fetch every item of a paginated createmeta endpoint (startAt paging) and
# print them as one JSON array. Fails if a page cannot be read or the page
# cap is hit before the last page, so callers never validate on partial data.
_scribe_jira_createmeta_all() {
  local endpoint="$1" items='[]' start=0 page resp count total last
  for ((page = 1; page <= SCRIBE_JIRA_MAX_PAGES; page++)); do
    resp=$(_scribe_jira_api GET "${endpoint}?maxResults=200&startAt=${start}") || return 1
    count=$(printf '%s' "${resp}" | jq -r '(.issueTypes // .values // .fields // []) | length') || return 1
    items=$(jq -cn --argjson cur "${items}" --argjson page "${resp}" \
      '$cur + ($page.issueTypes // $page.values // $page.fields // [])') || return 1
    total=$(printf '%s' "${resp}" | jq -r '.total // empty')
    last=$(printf '%s' "${resp}" | jq -r '.isLast // empty')
    start=$((start + count))
    # Without a total or isLast marker the response is a single page.
    if [[ "${count}" -eq 0 || "${last}" == "true" ]] \
      || [[ -z "${total}" && -z "${last}" ]] \
      || [[ -n "${total}" && "${start}" -ge "${total}" ]]; then
      printf '%s' "${items}"
      return 0
    fi
  done
  echo "ERROR: Jira create metadata exceeds ${SCRIBE_JIRA_MAX_PAGES} pages" >&2
  return 1
}

# Check that the configured project and issue type exist and that every
# required create field without a default is one scribe supplies. Fails
# before any create call when the project needs extra fields.
tracker_validate_create() {
  local types type_id meta missing
  types=$(_scribe_jira_createmeta_all "/issue/createmeta/${SCRIBE_JIRA_PROJECT}/issuetypes") || {
    echo "ERROR: cannot read create metadata for Jira project ${SCRIBE_JIRA_PROJECT} (missing project or no create permission)" >&2
    return 1
  }
  type_id=$(printf '%s' "${types}" | jq -r --arg name "${SCRIBE_JIRA_ISSUE_TYPE}" \
    '[.[] | select(.name == $name)][0].id // empty')
  if [[ -z "${type_id}" ]]; then
    echo "ERROR: issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' is not available in Jira project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  fi
  meta=$(_scribe_jira_createmeta_all "/issue/createmeta/${SCRIBE_JIRA_PROJECT}/issuetypes/${type_id}") || {
    echo "ERROR: cannot read create fields for issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' in Jira project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  }
  missing=$(printf '%s' "${meta}" | jq -r '
    [.[]
      | select(.required == true and (.hasDefaultValue // false) == false)
      | select((.fieldId // .key) as $f | ["project","issuetype","summary","description","labels","reporter"] | index($f) | not)
      | (.fieldId // .key)] | join(", ")')
  if [[ -n "${missing}" ]]; then
    echo "ERROR: Jira project ${SCRIBE_JIRA_PROJECT} requires fields scribe does not set: $(_gha_sanitize "${missing}")" >&2
    return 1
  fi
  # forge_create_issue sends description and labels; Jira rejects the create
  # when a field is not on the create screen. Description carries the issue
  # content, so fail clearly; labels are optional, so omit them instead.
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "description")' >/dev/null; then
    echo "ERROR: issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' in Jira project ${SCRIBE_JIRA_PROJECT} has no Description field on its create screen" >&2
    return 1
  fi
  SCRIBE_JIRA_LABELS_AVAILABLE=true
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "labels")' >/dev/null; then
    SCRIBE_JIRA_LABELS_AVAILABLE=false
    echo "WARNING: issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' in Jira project ${SCRIBE_JIRA_PROJECT} has no Labels field on its create screen; labels will be omitted" >&2
  fi
}

# Rerun protection: print the browse URL of an issue in the configured
# project whose summary exactly matches the title (any status). Paginates
# all matches of the fuzzy JQL summary search before comparing exactly.
# Returns 1 when the lookup cannot prove absence (API failure, no searchable
# terms, or results truncated by the page cap with no exact match) so callers
# refuse to create blindly.
tracker_find_existing_issue() {
  local title="$1" raw_file jql terms match rc=0
  # JQL text search reserves most punctuation; search on the letter/digit
  # terms only (Unicode-aware) and compare the full title exactly below.
  terms=$(printf '%s' "${title}" | jq -Rr '[scan("[\\p{L}\\p{N}]+")] | join(" ")') || return 1
  if [[ -z "${terms}" ]]; then
    echo "ERROR: Jira duplicate check has no searchable terms in the issue title" >&2
    return 1
  fi
  raw_file=$(mktemp)
  jql="project = $(_scribe_jql_quote "${SCRIBE_JIRA_PROJECT}") AND summary ~ $(_scribe_jql_quote "$(_scribe_jql_quote "${terms}")")"
  _scribe_jira_search_paginated "${jql}" '["summary"]' "${raw_file}" || rc=$?
  if [[ ${rc} -ne 0 && ${rc} -ne 2 ]]; then
    rm -f "${raw_file}"
    return 1
  fi
  if ! match=$(jq -rs --arg t "${title}" '[.[][] | select(.fields.summary == $t) | .key][0] // empty' "${raw_file}"); then
    rm -f "${raw_file}"
    echo "ERROR: Jira duplicate check could not parse search results" >&2
    return 1
  fi
  rm -f "${raw_file}"
  if [[ -n "${match}" ]]; then
    echo "${JIRA_BASE_URL}/browse/${match}"
  elif [[ ${rc} -eq 2 ]]; then
    echo "ERROR: Jira duplicate check was truncated by the page cap; cannot rule out an existing issue" >&2
    return 1
  fi
}

# Create an issue in SCRIBE_JIRA_PROJECT. Body is read from stdin. Labels
# are a comma-separated list; Jira labels cannot contain spaces, so spaces
# become hyphens. Returns the issue browse URL.
forge_create_issue() {
  local _repo="$1" title="$2" labels="$3"
  local desc labels_json payload response key
  desc=$(_scribe_text_to_adf)
  labels_json=$(jq -cn --arg l "${labels}" '[$l | split(",")[] | gsub("^\\s+|\\s+$"; "") | gsub("\\s+"; "-") | select(length > 0)] | unique')
  # tracker_validate_create sets SCRIBE_JIRA_LABELS_AVAILABLE=false when the
  # create screen has no Labels field; sending it would fail every create.
  if [[ "${SCRIBE_JIRA_LABELS_AVAILABLE:-true}" != "true" ]]; then
    labels_json='[]'
  fi
  payload=$(jq -cn --arg proj "${SCRIBE_JIRA_PROJECT}" --arg title "${title}" \
    --arg itype "${SCRIBE_JIRA_ISSUE_TYPE}" --argjson desc "${desc}" --argjson labels "${labels_json}" \
    '{fields: ({project: {key: $proj}, summary: $title, description: $desc, issuetype: {name: $itype}}
      + (if ($labels | length) > 0 then {labels: $labels} else {} end))}')
  response=$(_scribe_jira_api POST "/issue" --data "${payload}") || {
    echo "ERROR: forge_create_issue: Jira create failed in project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  }
  key=$(printf '%s' "${response}" | jq -r '.key // empty' 2>/dev/null)
  if [[ ! "${key}" =~ ^${SCRIBE_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: forge_create_issue: Jira response missing a valid issue key" >&2
    return 1
  fi
  echo "${JIRA_BASE_URL}/browse/${key}"
}

forge_issue_url_base() {
  echo "${JIRA_BASE_URL}/browse"
}
# END bundled: lib/jira-scribe-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_TRACKER: '$(_gha_sanitize "${FULLSEND_TRACKER}")' — must be 'jira' or match FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/scribe-ops.lib.sh

if [[ -n "${GH_TOKEN:-}" ]]; then
  echo "::add-mask::${GH_TOKEN}"
fi
if [[ -n "${GITLAB_TOKEN:-}" ]]; then
  echo "::add-mask::${GITLAB_TOKEN}"
fi
if [[ -n "${JIRA_TOKEN:-}" ]]; then
  echo "::add-mask::${JIRA_TOKEN}"
fi

# ============================================================
# HARD SAFETY GATE — refuse to write if dry-run is not set
# ============================================================
if [[ -z "${SCRIBE_DRY_RUN:-}" ]]; then
  echo "ERROR: SCRIBE_DRY_RUN is not set. Refusing to run."
  echo "Set SCRIBE_DRY_RUN=true for preview or SCRIBE_DRY_RUN=false for live writes."
  exit 1
fi

DRY_RUN="true"
if [[ "${SCRIBE_DRY_RUN}" == "false" ]]; then
  DRY_RUN="false"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "::notice::DRY RUN — no repository writes will be performed"
fi

WOULD_BE=""
[[ "${DRY_RUN}" == "true" ]] && WOULD_BE="would be "

# ============================================================
# Mode: comments_only, new_issues_only, or all (default)
# ============================================================
SCRIBE_MODE="${SCRIBE_MODE:-all}"
case "${SCRIBE_MODE}" in
  all|comments_only|new_issues_only) ;;
  *)
    echo "ERROR: SCRIBE_MODE must be 'all', 'comments_only', or 'new_issues_only' (got: ${SCRIBE_MODE})"
    exit 1
    ;;
esac
# Jira: existing_issue is a numeric forge issue number, so comments on Jira
# issues are not supported yet. Only new issues are written.
if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
  if [[ "${SCRIBE_MODE}" == "comments_only" ]]; then
    echo "ERROR: SCRIBE_MODE=comments_only is not supported with FULLSEND_TRACKER=jira (comments are not supported)"
    exit 1
  fi
  if [[ "${SCRIBE_MODE}" == "all" ]]; then
    echo "::notice::FULLSEND_TRACKER=jira — comments are not supported; using new_issues_only"
    SCRIBE_MODE="new_issues_only"
  fi
fi
echo "Mode: ${SCRIBE_MODE}"

# Find the agent result JSON — prefer the validated iteration when set.
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent. No containment check
# (realpath / prefix guard) is applied here; the value is trusted from the
# external harness. If the trust model changes, add a realpath prefix check.
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  if [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  elif [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/result.json" ]]; then
    # Agents sometimes write "result.json" instead of "agent-result.json";
    # validate-output-schema.sh accepts that filename as a fallback without
    # renaming it (scribe.yaml uses the default agent-result.json filename,
    # so this fallback is reachable in practice).
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/result.json"
  else
    echo "ERROR: FULLSEND_VALIDATED_ITERATION_DIR is set but contains neither agent-result.json nor result.json"
    exit 1
  fi
else
  # Backward compatibility: scan iteration-N/ subdirectories for the last
  # iteration's output (glob order = naturally ascending iteration numbers).
  RESULT_FILE=""
  for dir in iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      RESULT_FILE="${dir}/agent-result.json"
    fi
  done
fi

if [[ -z "${RESULT_FILE}" ]] || [[ ! -f "${RESULT_FILE}" ]]; then
  echo "ERROR: agent-result.json not found in any iteration output directory"
  exit 1
fi

echo "Reading scribe result from: ${RESULT_FILE}"

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

# ============================================================
# Security gate — deterministic checks on every topic
# ============================================================

MIN_CONFIDENCE="${SCRIBE_MIN_CONFIDENCE:-0.6}"
MAX_COMMENT_LEN=2000
MAX_BODY_LEN=15000
MAX_TITLE_LEN=200

is_valid_confidence() {
  [[ "${1}" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

if ! is_valid_confidence "${MIN_CONFIDENCE}"; then
  echo "ERROR: SCRIBE_MIN_CONFIDENCE must be a number between 0.0 and 1.0 (got: ${MIN_CONFIDENCE})"
  exit 1
fi
if (( $(echo "${MIN_CONFIDENCE} < 0 || ${MIN_CONFIDENCE} > 1" | bc -l) )); then
  echo "ERROR: SCRIBE_MIN_CONFIDENCE must be between 0.0 and 1.0 (got: ${MIN_CONFIDENCE})"
  exit 1
fi
echo "Confidence threshold: ${MIN_CONFIDENCE}"
REJECTED=0

contains_sensitive() {
  local text="$1"
  # GitHub PATs, AWS access keys, private keys
  echo "${text}" \
    | grep -qEi '(ghp|gho|ghs|ghr)_[A-Za-z0-9_]{36,}|\b(AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b|-----BEGIN.*(PRIVATE KEY)' \
    && return 0
  # Email addresses
  echo "${text}" \
    | grep -qE '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b' \
    && return 0
  # SSN
  echo "${text}" \
    | grep -qE '\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b' \
    && return 0
  # Slack webhooks
  echo "${text}" \
    | grep -qE 'https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+' \
    && return 0
  # JWTs
  echo "${text}" \
    | grep -qE '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b' \
    && return 0
  # Generic key=value secrets
  echo "${text}" \
    | grep -qEi '(api[_-]?key|token|secret|password|bearer)[[:space:]]*[:=][[:space:]]*['"'"'"]?[A-Za-z0-9_.~+/-]{20,}' \
    && return 0
  return 1
}

contains_suspicious_unicode() {
  local text="$1"
  # Tag characters (U+E0000–E007F), zero-width chars, BOM, bidi overrides/isolates
  echo "${text}" \
    | perl -e 'binmode(STDIN, q(:encoding(UTF-8))); while (<STDIN>) { if (/[\x{E0000}-\x{E007F}\x{200B}\x{200C}\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}]/) { exit 0 } } exit 1' \
    && return 0
  return 1
}

# Escape Slack mrkdwn metacharacters in link labels.
sanitize_slack_mrkdwn() {
  local val="$1"
  val="${val//&/&amp;}"
  val="${val//</&lt;}"
  val="${val//>/&gt;}"
  val="${val//|/¦}"
  printf '%s' "${val}"
}

CONTENT_GATE_REJECTIONS=0

gate_reject() {
  local topic="$1" reason="$2"
  topic=$(_gha_sanitize "${topic}")
  reason=$(_gha_sanitize "${reason}")
  echo "  GATE REJECTED: [${topic}] — ${reason}"
  REJECTED=$((REJECTED + 1))
}

gate_reject_content() {
  local index="$1" total="$2" category="$3"
  category=$(_gha_sanitize "${category}")
  echo "  GATE REJECTED: item ${index} of ${total} — content gate: ${category}"
  REJECTED=$((REJECTED + 1))
  CONTENT_GATE_REJECTIONS=$((CONTENT_GATE_REJECTIONS + 1))
}

# ============================================================
# Dedup: merge topics referencing the same existing issue
# ============================================================
# If the LLM produces multiple entries for the same issue despite being asked
# not to, merge them: combine summaries, keep the highest confidence, keep
# public_safe=false if any entry is unsafe.
DEDUP_FILE="${RESULT_FILE}.deduped"
jq --argjson max_len "${MAX_COMMENT_LEN}" '
  .topics as $all |
  ($all | map(select(.existing_issue != null)) | group_by(.existing_issue) |
    map(
      if length == 1 then .[0]
      else
        reduce .[1:][] as $t (.[0];
          .summary = ((.summary // "") + (if (.summary // "") != "" and ($t.summary // "") != "" then "\n\n" else "" end) + ($t.summary // "")) |
          .confidence = ([.confidence, $t.confidence] | max) |
          if $t.public_safe == false then .public_safe = false | .public_safe_category = $t.public_safe_category else . end
        )
      end
      | if ((.summary // "") | length) > $max_len then
          .summary = ((.summary // "")[0:($max_len - 16)] + "\n\n_(truncated)_")
        else . end
    )
  ) as $merged |
  ($all | map(select(.existing_issue == null))) as $rest |
  . + {topics: ($merged + $rest)}
' "${RESULT_FILE}" > "${DEDUP_FILE}"

ORIG_COUNT=$(jq '.topics | length' "${RESULT_FILE}")
DEDUP_COUNT=$(jq '.topics | length' "${DEDUP_FILE}")
if [[ "${ORIG_COUNT}" -ne "${DEDUP_COUNT}" ]]; then
  echo "Dedup: merged ${ORIG_COUNT} → ${DEDUP_COUNT} topics ($(( ORIG_COUNT - DEDUP_COUNT )) duplicates)"
  RESULT_FILE="${DEDUP_FILE}"
else
  rm -f "${DEDUP_FILE}"
fi

# Tracking arrays for step summary (parallel indexed lists)
COMMENT_TOPICS=()
COMMENT_ISSUES=()
NEW_ISSUE_TITLES=()
NEW_ISSUE_URLS=()
SKIPPED_NEW_ISSUES=0

# ============================================================
# Process comment topics (existing issues)
# ============================================================
TOPIC_COUNT=$(jq '.topics | length' "${RESULT_FILE}")

if [[ "${SCRIBE_MODE}" == "new_issues_only" ]]; then
  echo "Skipping ${TOPIC_COUNT} comment topics (mode: new_issues_only)"
  TOPIC_COUNT=0
else
  echo "Processing ${TOPIC_COUNT} topics for existing issues..."
fi

for i in $(seq 0 $((TOPIC_COUNT - 1))); do
  # Read public_safe FIRST — if false, we must not log topic title or content
  PUBLIC_SAFE=$(jq -r ".topics[${i}].public_safe" "${RESULT_FILE}")
  PUBLIC_SAFE_CAT=$(jq -r ".topics[${i}].public_safe_category // empty" "${RESULT_FILE}")

  if [[ "${PUBLIC_SAFE}" == "false" ]]; then
    if [[ -z "${PUBLIC_SAFE_CAT}" || "${PUBLIC_SAFE_CAT}" == "null" ]]; then
      PUBLIC_SAFE_CAT="unspecified"
    fi
    gate_reject_content "$((i + 1))" "${TOPIC_COUNT}" "${PUBLIC_SAFE_CAT}"
    continue
  fi

  TOPIC=$(jq -r ".topics[${i}].topic" "${RESULT_FILE}")
  SUMMARY=$(jq -r ".topics[${i}].summary" "${RESULT_FILE}")
  CONFIDENCE=$(jq -r ".topics[${i}].confidence" "${RESULT_FILE}")
  ISSUE_NUM=$(jq -r ".topics[${i}].existing_issue // empty" "${RESULT_FILE}")
  OMIT=$(jq -r ".topics[${i}].omit_reason // empty" "${RESULT_FILE}")

  if [[ -n "${OMIT}" ]]; then
    echo "  OMITTED: [$(_gha_sanitize "${TOPIC}")] — $(_gha_sanitize "${OMIT}")"
    continue
  fi

  if [[ -z "${ISSUE_NUM}" || "${ISSUE_NUM}" == "null" ]]; then
    continue
  fi

  if [[ ! "${ISSUE_NUM}" =~ ^[1-9][0-9]*$ ]]; then
    gate_reject "${TOPIC}" "invalid existing_issue number"
    continue
  fi

  if [[ -z "${SUMMARY}" || "${SUMMARY}" == "null" ]]; then
    gate_reject "${TOPIC}" "missing or null summary for existing issue comment"
    continue
  fi

  # Gate: confidence
  if ! is_valid_confidence "${CONFIDENCE}"; then
    gate_reject "${TOPIC}" "invalid confidence value"
    continue
  fi
  if (( $(echo "${CONFIDENCE} < ${MIN_CONFIDENCE}" | bc -l) )); then
    gate_reject "${TOPIC}" "confidence ${CONFIDENCE} below threshold ${MIN_CONFIDENCE}"
    continue
  fi

  # Gate: sensitive content (deterministic PII/secret patterns)
  if contains_sensitive "${SUMMARY}" || contains_sensitive "${TOPIC}"; then
    gate_reject "${TOPIC}" "contains sensitive content (PII, secrets)"
    continue
  fi

  # Gate: suspicious Unicode (prompt injection defense)
  if contains_suspicious_unicode "${SUMMARY}" || contains_suspicious_unicode "${TOPIC}"; then
    gate_reject "${TOPIC}" "contains suspicious Unicode (potential prompt injection)"
    continue
  fi

  # Gate: length
  SUMMARY_LEN=${#SUMMARY}
  if [[ ${SUMMARY_LEN} -gt ${MAX_COMMENT_LEN} ]]; then
    gate_reject "${TOPIC}" "summary length ${SUMMARY_LEN} exceeds max ${MAX_COMMENT_LEN}"
    continue
  fi

  # Gate: code blocks in comments
  if echo "${SUMMARY}" | grep -q '```'; then
    gate_reject "${TOPIC}" "comment contains code block (unexpected in meeting summary)"
    continue
  fi

  SAFE_TOPIC=$(_gha_sanitize "${TOPIC}")
  SAFE_CONFIDENCE=$(_gha_sanitize "${CONFIDENCE}")
  echo "  PASS: [${SAFE_TOPIC}] → comment on #${ISSUE_NUM} (confidence: ${SAFE_CONFIDENCE})"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY RUN] Would post comment to ${SCRIBE_REPO}#${ISSUE_NUM}"
    COMMENT_TOPICS+=("${SAFE_TOPIC}")
    COMMENT_ISSUES+=("${ISSUE_NUM}")
  else
    # Idempotency: prefer notes URL; fall back to issue + topic + meeting date
    NOTES_URL=$(printf '%s' "${SUMMARY}" | grep -oP '\[Meeting notes\]\(\K[^)]+' || echo "")
    MEETING_DATE=$(printf '%s' "${SUMMARY}" | grep -oP '(?<=\*\*Meeting update — ).*?(?=\*\*)' || echo "")
    EXISTING=0
    COMMENTS_JSON=$(forge_list_issue_comments "${SCRIBE_REPO}" "${ISSUE_NUM}")
    if [[ -n "${NOTES_URL}" ]]; then
      EXISTING=$(echo "${COMMENTS_JSON}" \
        | jq --arg url "${NOTES_URL}" '[.[] | select(.body | contains($url))] | length' \
        2>/dev/null || echo "0")
    elif [[ -n "${MEETING_DATE}" ]]; then
      EXISTING=$(echo "${COMMENTS_JSON}" \
        | jq --arg date "${MEETING_DATE}" --arg topic "${TOPIC}" \
          '[.[] | select(.body | contains("**Meeting update — " + $date + "**") and contains($topic))] | length' \
          2>/dev/null || echo "0")
    fi
    if [[ "${EXISTING}" -gt 0 ]]; then
      echo "    SKIP: duplicate comment (already posted for this meeting/issue)"
      continue
    fi

    printf '%s' "${SUMMARY}" | forge_post_issue_comment "${SCRIBE_REPO}" "${ISSUE_NUM}"
    COMMENT_TOPICS+=("${SAFE_TOPIC}")
    COMMENT_ISSUES+=("${ISSUE_NUM}")
  fi
done

# ============================================================
# Process new issues
# ============================================================
NEW_COUNT=$(jq '.new_issues | length' "${RESULT_FILE}")

if [[ "${SCRIBE_MODE}" == "comments_only" ]]; then
  echo "Skipping ${NEW_COUNT} new issue proposals (mode: comments_only)"
  SKIPPED_NEW_ISSUES=${NEW_COUNT}
  NEW_COUNT=0
else
  echo "Processing ${NEW_COUNT} new issue proposals..."
fi

# Jira: fail before any create call if the configured project/issue type
# needs required fields scribe does not set.
if [[ "${FULLSEND_TRACKER}" == "jira" ]] && [[ "${NEW_COUNT}" -gt 0 ]]; then
  if ! tracker_validate_create; then
    echo "ERROR: Jira project validation failed — no issues created"
    exit 1
  fi
fi

for i in $(seq 0 $((NEW_COUNT - 1))); do
  # Read public_safe FIRST — if false, suppress all content from logs
  PUBLIC_SAFE=$(jq -r ".new_issues[${i}].public_safe" "${RESULT_FILE}")
  PUBLIC_SAFE_CAT=$(jq -r ".new_issues[${i}].public_safe_category // empty" "${RESULT_FILE}")

  if [[ "${PUBLIC_SAFE}" == "false" ]]; then
    if [[ -z "${PUBLIC_SAFE_CAT}" || "${PUBLIC_SAFE_CAT}" == "null" ]]; then
      PUBLIC_SAFE_CAT="unspecified"
    fi
    gate_reject_content "$((i + 1))" "${NEW_COUNT}" "${PUBLIC_SAFE_CAT}"
    continue
  fi

  TITLE=$(jq -r ".new_issues[${i}].title" "${RESULT_FILE}")
  BODY=$(jq -r ".new_issues[${i}].body" "${RESULT_FILE}")
  CONFIDENCE=$(jq -r ".new_issues[${i}].confidence" "${RESULT_FILE}")
  LABELS=$(jq -r ".new_issues[${i}].labels // [\"meeting-notes\"] | join(\",\")" "${RESULT_FILE}")

  # Gate: confidence
  if ! is_valid_confidence "${CONFIDENCE}"; then
    gate_reject "${TITLE}" "invalid confidence value"
    continue
  fi
  if (( $(echo "${CONFIDENCE} < ${MIN_CONFIDENCE}" | bc -l) )); then
    gate_reject "${TITLE}" "confidence ${CONFIDENCE} below threshold ${MIN_CONFIDENCE}"
    continue
  fi

  # Gate: sensitive content (deterministic PII/secret patterns)
  # Labels are model-produced free text (Jira creates them on the fly), so
  # they pass the same gates as the title and body.
  if contains_sensitive "${TITLE}" || contains_sensitive "${BODY}" || contains_sensitive "${LABELS}"; then
    gate_reject "${TITLE}" "contains sensitive content"
    continue
  fi

  # Gate: suspicious Unicode (prompt injection defense)
  if contains_suspicious_unicode "${TITLE}" || contains_suspicious_unicode "${BODY}" || contains_suspicious_unicode "${LABELS}"; then
    gate_reject "${TITLE}" "contains suspicious Unicode (potential prompt injection)"
    continue
  fi

  # Gate: lengths
  TITLE_LEN=${#TITLE}
  BODY_LEN=${#BODY}
  if [[ ${TITLE_LEN} -gt ${MAX_TITLE_LEN} ]]; then
    gate_reject "${TITLE}" "title length ${TITLE_LEN} exceeds max ${MAX_TITLE_LEN}"
    continue
  fi
  if [[ ${BODY_LEN} -gt ${MAX_BODY_LEN} ]]; then
    gate_reject "${TITLE}" "body length ${BODY_LEN} exceeds max ${MAX_BODY_LEN}"
    continue
  fi

  # Gate: code blocks in issue bodies
  if echo "${BODY}" | grep -q '```'; then
    gate_reject "${TITLE}" "issue body contains code block (unexpected in meeting summary)"
    continue
  fi

  SAFE_TITLE=$(_gha_sanitize "${TITLE}")
  SAFE_CONFIDENCE=$(_gha_sanitize "${CONFIDENCE}")
  echo "  PASS: [${SAFE_TITLE}] → new issue (confidence: ${SAFE_CONFIDENCE})"
  NEW_ISSUE_TITLES+=("${SAFE_TITLE}")

  # Prepend auto-generated banner so reviewers know this was machine-created
  BANNER='> [!NOTE]
> This issue was automatically generated from meeting notes by the scribe agent.
> Please review, edit, and add any missing context before prioritizing.

'
  FULL_BODY="${BANNER}${BODY}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY RUN] Would create issue: ${SAFE_TITLE}"
    echo "    [DRY RUN] Labels: $(_gha_sanitize "${LABELS}")"
    echo "    [DRY RUN] Body length: ${BODY_LEN} chars"
    NEW_ISSUE_URLS+=("")
  else
    # Jira rerun protection: skip if an issue with the same summary exists.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      if ! EXISTING_URL=$(tracker_find_existing_issue "${TITLE}"); then
        echo "ERROR: Jira duplicate check failed — refusing to create issue"
        exit 1
      fi
      if [[ -n "${EXISTING_URL}" ]]; then
        echo "    SKIP: duplicate issue (already exists: ${EXISTING_URL})"
        unset 'NEW_ISSUE_TITLES[-1]'
        continue
      fi
    fi
    ISSUE_URL=$(printf '%s' "${FULL_BODY}" | forge_create_issue "${SCRIBE_REPO}" "${TITLE}" "${LABELS}")
    echo "    Created: ${ISSUE_URL}"
    NEW_ISSUE_URLS+=("${ISSUE_URL}")
  fi
done

# ============================================================
# Summary (console)
# ============================================================
RUN_MODE_LABEL="LIVE"
[[ "${DRY_RUN}" == "true" ]] && RUN_MODE_LABEL="DRY RUN"

echo ""
echo "=== Scribe Post-Script Summary ==="
echo "  Run mode: ${RUN_MODE_LABEL}"
echo "  Agent mode: ${SCRIBE_MODE}"
echo "  Topics processed: ${TOPIC_COUNT}"
echo "  Comments ${WOULD_BE}posted: ${#COMMENT_TOPICS[@]}"
echo "  New issues ${WOULD_BE}created: ${#NEW_ISSUE_TITLES[@]}"
echo "  Gate rejections: ${REJECTED}"
echo "    Content gate: ${CONTENT_GATE_REJECTIONS}"
echo "  New proposals reviewed: ${NEW_COUNT}"
[[ "${SKIPPED_NEW_ISSUES}" -gt 0 ]] && echo "  Skipped new issues (mode): ${SKIPPED_NEW_ISSUES}"
echo "=================================="

# ============================================================
# Step summary — markdown report for CI job page
# ============================================================
ISSUE_BASE=$(forge_issue_url_base "${SCRIBE_REPO}")
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
{
  echo "### Scribe agent report (${RUN_MODE_LABEL})"
  echo ""
  echo "| Metric | Count |"
  echo "|--------|------:|"
  echo "| Topics processed | ${TOPIC_COUNT} |"
  echo "| Comments ${WOULD_BE}posted | ${#COMMENT_TOPICS[@]} |"
  echo "| New issues ${WOULD_BE}created | ${#NEW_ISSUE_TITLES[@]} |"
  echo "| Gate rejections | ${REJECTED} |"
  echo "| Content gate rejections | ${CONTENT_GATE_REJECTIONS} |"
  if [[ "${SKIPPED_NEW_ISSUES}" -gt 0 ]]; then
    echo "| Skipped (${SCRIBE_MODE}) | ${SKIPPED_NEW_ISSUES} |"
  fi
  echo ""

  if [[ ${#COMMENT_TOPICS[@]} -gt 0 ]]; then
    echo "**Comments ${WOULD_BE}posted:** ${#COMMENT_TOPICS[@]}"
    for idx in "${!COMMENT_TOPICS[@]}"; do
      echo "- [#${COMMENT_ISSUES[$idx]} — ${COMMENT_TOPICS[$idx]}](${ISSUE_BASE}/${COMMENT_ISSUES[$idx]})"
    done
    echo ""
  fi

  if [[ ${#NEW_ISSUE_TITLES[@]} -gt 0 ]]; then
    echo "**New issues ${WOULD_BE}filed:** ${#NEW_ISSUE_TITLES[@]}"
    for idx in "${!NEW_ISSUE_TITLES[@]}"; do
      if [[ -n "${NEW_ISSUE_URLS[$idx]:-}" ]]; then
        echo "- [${NEW_ISSUE_TITLES[$idx]}](${NEW_ISSUE_URLS[$idx]})"
      else
        echo "- ${NEW_ISSUE_TITLES[$idx]}"
      fi
    done
    echo ""
  fi

  if [[ "${REJECTED}" -gt 0 ]]; then
    echo "> **${REJECTED}** topic(s) rejected by the security gate."
    if [[ "${CONTENT_GATE_REJECTIONS}" -gt 0 ]]; then
      echo "> ${CONTENT_GATE_REJECTIONS} rejected by content gate (details suppressed for safety)."
    fi
    echo ""
  fi

  echo "_Confidence threshold: ${MIN_CONFIDENCE} · Mode: ${SCRIBE_MODE}_"
} >> "${GITHUB_STEP_SUMMARY}"
  echo "Step summary written to GITHUB_STEP_SUMMARY"
fi

# ============================================================
# Slack notification (optional — skip silently if no webhook)
# ============================================================
SLACK_WEBHOOK="${SCRIBE_SLACK_WEBHOOK_URL:-${SLACK_WEBHOOK_URL:-}}"
if [[ -n "${SLACK_WEBHOOK}" ]]; then
  echo "::add-mask::${SLACK_WEBHOOK}"
  RUN_URL=$(forge_run_url "${SCRIBE_REPO}")

  SLACK_TEXT=":memo: *Scribe agent* (${RUN_MODE_LABEL})"
  SLACK_TEXT+="\nMode: \`${SCRIBE_MODE}\` · Confidence: \`${MIN_CONFIDENCE}\`"
  SLACK_TEXT+="\n• Topics processed: *${TOPIC_COUNT}*"
  SLACK_TEXT+="\n• Comments: *${#COMMENT_TOPICS[@]}*"
  SLACK_TEXT+="\n• New issues: *${#NEW_ISSUE_TITLES[@]}*"
  SLACK_TEXT+="\n• Gate rejections: *${REJECTED}*"
  if [[ "${CONTENT_GATE_REJECTIONS}" -gt 0 ]]; then
    SLACK_TEXT+=" (${CONTENT_GATE_REJECTIONS} content)"
  fi
  if [[ "${SKIPPED_NEW_ISSUES}" -gt 0 ]]; then
    SLACK_TEXT+="\n• Skipped (${SCRIBE_MODE}): *${SKIPPED_NEW_ISSUES}*"
  fi

  if [[ ${#COMMENT_TOPICS[@]} -gt 0 ]]; then
    SLACK_TEXT+="\n\n*Comments:*"
    for idx in "${!COMMENT_TOPICS[@]}"; do
      SLACK_TOPIC=$(sanitize_slack_mrkdwn "${COMMENT_TOPICS[$idx]}")
      SLACK_TEXT+="\n  • <${ISSUE_BASE}/${COMMENT_ISSUES[$idx]}|#${COMMENT_ISSUES[$idx]} — ${SLACK_TOPIC}>"
    done
  fi

  if [[ ${#NEW_ISSUE_TITLES[@]} -gt 0 ]]; then
    SLACK_TEXT+="\n\n*New issues:*"
    for idx in "${!NEW_ISSUE_TITLES[@]}"; do
      SLACK_TITLE=$(sanitize_slack_mrkdwn "${NEW_ISSUE_TITLES[$idx]}")
      if [[ -n "${NEW_ISSUE_URLS[$idx]:-}" ]]; then
        SLACK_TEXT+="\n  • <${NEW_ISSUE_URLS[$idx]}|${SLACK_TITLE}>"
      else
        SLACK_TEXT+="\n  • ${SLACK_TITLE}"
      fi
    done
  fi

  SLACK_TEXT+="\n\n<${RUN_URL}|View run>"

  SLACK_PAYLOAD=$(printf '%b' "${SLACK_TEXT}" | jq -Rs '{text: .}')
  if printf '%s' "${SLACK_PAYLOAD}" \
      | curl -fsSL -X POST -H 'Content-Type: application/json' \
        --data-binary @- "${SLACK_WEBHOOK}" >/dev/null 2>&1; then
    echo "Slack notification sent"
  else
    echo "WARNING: Slack notification failed (non-fatal)"
  fi
  unset SLACK_WEBHOOK
else
  echo "No SCRIBE_SLACK_WEBHOOK_URL set — skipping Slack notification"
fi
