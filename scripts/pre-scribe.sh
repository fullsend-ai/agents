#!/usr/bin/env bash
# GENERATED from pre-scribe.src.sh — DO NOT EDIT. Run: make script-build
# pre-scribe.sh — Fetch meeting notes from Google Drive, scrub PII, prepare
# workspace for the scribe agent.
#
# Runs on the host before the sandbox starts. Downloads recent meeting notes,
# strips sensitive content, and prepares input files the agent will read.
#
# Required env vars:
#   SCRIBE_REPO           — target repository (owner/name or group/project)
#   SCRIBE_SEARCH_QUERY   — Drive doc name search (e.g. "team sync")
#   FULLSEND_FORGE        — "github" or "gitlab"
#   GOOGLE_APPLICATION_CREDENTIALS — path to GCP SA credentials
#
# Forge-specific token env vars:
#   GH_TOKEN       — GitHub token (when FULLSEND_FORGE=github)
#   GITLAB_TOKEN   — GitLab token (when FULLSEND_FORGE=gitlab)
#
# Jira backlog (FULLSEND_TRACKER=jira): see lib/jira-scribe-ops.lib.sh for
# JIRA_BASE_URL, JIRA_USER_EMAIL, JIRA_TOKEN, SCRIBE_JIRA_PROJECT.
#
# Optional env vars:
#   SCRIBE_NAME_FILTER    — substring filter on doc names
#   SCRIBE_LOOKBACK_HOURS — how far back to search (default: 3)

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
# Requires fullsend >= the release that ships `fullsend issues create
# --tracker jira` (fullsend#7083 / fullsend#8499). The post-script
# validates this at preflight time via tracker_validate_create.
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

# Like _scribe_jira_api but captures the HTTP status code and returns the
# response body even on error, so callers can log field-level rejection
# reasons instead of a generic "failed" message.
_scribe_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file raw http_code body
  err_file=$(mktemp)
  raw=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${JIRA_BASE_URL}/rest/api/3${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "Jira API error: curl failed — $(_gha_sanitize "$(cat "${err_file}")")" >&2
    rm -f "${err_file}"
    return 1
  }
  rm -f "${err_file}"
  http_code=$(printf '%s' "${raw}" | tail -1)
  body=$(printf '%s' "${raw}" | sed '$d')
  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    local errors
    errors=$(printf '%s' "${body}" | jq -r '(.errorMessages // []) + [(.errors // {} | to_entries[] | "\(.key): \(.value)")] | join("; ")' 2>/dev/null || echo "")
    echo "Jira API error (HTTP ${http_code}): $(_gha_sanitize "${errors:-${body}}")" >&2
    return 1
  fi
  printf '%s' "${body}"
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
    if [[ "${is_last}" == "true" ]]; then
      return 0
    fi
    if [[ -z "${token}" ]]; then
      echo "ERROR: Jira JQL search returned isLast=false with no nextPageToken" >&2
      return 1
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
  if [[ ${rc} -eq 2 ]]; then
    # shellcheck disable=SC2034 # SCRIBE_BACKLOG_PAGE_CAPPED consumed by pre-scribe
    SCRIBE_BACKLOG_PAGE_CAPPED=true
    return 2
  fi
  return ${rc}
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

# Add labels to an existing Jira issue via the REST API. Labels are a
# comma-separated list; Jira labels cannot contain spaces, so spaces
# become hyphens.
_scribe_jira_add_labels() {
  local key="$1" labels="$2"
  local labels_json ops
  labels_json=$(jq -cn --arg l "${labels}" '[$l | split(",")[] | gsub("^\\s+|\\s+$"; "") | gsub("\\s+"; "-") | select(length > 0)]')
  if [[ "$(printf '%s' "${labels_json}" | jq 'length')" -eq 0 ]]; then
    return 0
  fi
  ops=$(printf '%s' "${labels_json}" | jq '{update:{labels:[.[] | {add:.}]}}')
  _scribe_jira_api_with_status PUT "/issue/${key}" --data "${ops}" > /dev/null
}

# Fetch every item of a paginated createmeta endpoint (startAt paging) and
# print them as one JSON array. Fails if a page cannot be read or the page
# cap is hit before the last page, so callers never validate on partial data.
_scribe_jira_createmeta_all() {
  local endpoint="$1" start=0 page resp count total last
  local items_file
  items_file=$(mktemp)
  printf '[]' > "${items_file}"
  for ((page = 1; page <= SCRIBE_JIRA_MAX_PAGES; page++)); do
    resp=$(_scribe_jira_api GET "${endpoint}?maxResults=200&startAt=${start}") || { rm -f "${items_file}"; return 1; }
    count=$(printf '%s' "${resp}" | jq -r '(.issueTypes // .values // .fields // []) | length') || { rm -f "${items_file}"; return 1; }
    # Merge page items via stdin/file to avoid --argjson argument-size limits
    # on projects with large allowedValues lists. Strip allowedValues to
    # reduce accumulated size since it is not needed for validation.
    if printf '%s' "${resp}" | jq -c '(.issueTypes // .values // .fields // []) | map(del(.allowedValues))' \
      | jq -sc '.[0] + .[1]' "${items_file}" - > "${items_file}.tmp" \
      && mv "${items_file}.tmp" "${items_file}"; then
      :
    else
      rm -f "${items_file}" "${items_file}.tmp"
      return 1
    fi
    total=$(printf '%s' "${resp}" | jq -r '.total // empty')
    # Distinguish absent isLast from explicit false: jq's `// empty`
    # converts false to empty, so use has() to detect absence.
    last=$(printf '%s' "${resp}" | jq -r 'if has("isLast") then (.isLast | tostring) else "absent" end')
    start=$((start + count))
    # Without a total or isLast marker the response is a single page.
    if [[ "${count}" -eq 0 || "${last}" == "true" ]] \
      || [[ -z "${total}" && "${last}" == "absent" ]] \
      || [[ -n "${total}" && "${start}" -ge "${total}" ]]; then
      cat "${items_file}"
      rm -f "${items_file}"
      return 0
    fi
  done
  rm -f "${items_file}"
  echo "ERROR: Jira create metadata exceeds ${SCRIBE_JIRA_MAX_PAGES} pages" >&2
  return 1
}

# Check that the configured project and issue type exist and that every
# required create field without a default is one scribe supplies. Fails
# before any create call when the project needs extra fields.
tracker_validate_create() {
  local types type_id meta missing
  # Preflight: verify that the fullsend CLI ships `issues create`.
  # This subcommand was introduced in fullsend#8499 and may not be
  # present in older binaries. Failing here surfaces the problem on
  # dry-run instead of silently passing validation and then exploding
  # on the first live create.
  if ! fullsend issues create --help >/dev/null 2>&1; then
    echo "ERROR: 'fullsend issues create' is not available — upgrade fullsend to a version that includes issues create (fullsend#8499)" >&2
    return 1
  fi
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
      | select((.fieldId // .key) as $f | ["project","issuetype","summary","description"] | index($f) | not)
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
#
# Delegates the actual POST to `fullsend issues create --tracker jira`,
# which handles Markdown-to-ADF conversion and the Jira REST call.
# Labels are added separately via the REST API because the CLI does not
# support a --labels flag.
forge_create_issue() {
  local _repo="$1" title="$2" labels="$3"
  local body response key url
  body=$(cat)
  response=$(printf '%s' "${body}" | fullsend issues create \
    --tracker jira \
    --project "${SCRIBE_JIRA_PROJECT}" \
    --type "${SCRIBE_JIRA_ISSUE_TYPE}" \
    --title "${title}" \
    --body - \
    --jira-url "${JIRA_BASE_URL}" \
    --jira-email "${JIRA_USER_EMAIL}") || {
    echo "ERROR: forge_create_issue: fullsend issues create failed in project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  }
  key=$(printf '%s' "${response}" | jq -r '.key // empty' 2>/dev/null)
  url=$(printf '%s' "${response}" | jq -r '.url // empty' 2>/dev/null)
  if [[ -z "${key}" ]] || [[ ! "${key}" =~ ^${SCRIBE_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: forge_create_issue: fullsend issues create returned no valid issue key" >&2
    return 1
  fi
  # tracker_validate_create sets SCRIBE_JIRA_LABELS_AVAILABLE=false when the
  # create screen has no Labels field; sending it would fail every create.
  # Note: SCRIBE_JIRA_LABELS_AVAILABLE is validated against createmeta (create
  # screen). The label PUT uses the edit screen, which usually agrees with the
  # create screen for the Labels field but is not separately validated. If the
  # edit screen differs, the PUT will fail and the issue is created without
  # labels — surfaced in the step summary and Slack output below.
  local label_failed=false
  if [[ "${SCRIBE_JIRA_LABELS_AVAILABLE:-true}" == "true" ]] && [[ -n "${labels}" ]]; then
    if ! _scribe_jira_add_labels "${key}" "${labels}"; then
      echo "WARNING: forge_create_issue: failed to add labels to ${key} (issue created without labels)" >&2
      label_failed=true
    fi
  fi
  if [[ -n "${url}" ]]; then
    echo "${url}"
  else
    echo "${JIRA_BASE_URL}/browse/${key}"
  fi
  # Return 2 to signal "created successfully but labels failed" so the
  # caller (post-scribe) can surface the failure in the run summary.
  [[ "${label_failed}" == "true" ]] && return 2
  return 0
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
  # Sanitize workflow-command delimiters before interpolating into ::add-mask::
  # so a crafted token cannot inject additional workflow commands.
  printf '::add-mask::%s\n' "$(printf '%s' "${JIRA_TOKEN}" | tr -d '\n\r')"
fi

WORK_DIR="${RUNNER_TEMP:-/tmp}/scribe-workspace"
NOTES_DIR="${WORK_DIR}/notes"
BACKLOG_FILE="${WORK_DIR}/backlog.json"
META_FILE="${WORK_DIR}/scribe-meta.json"

mkdir -p "${NOTES_DIR}"

LOOKBACK="${SCRIBE_LOOKBACK_HOURS:-3}"
# RFC3339 with Z suffix — matches the Go code's time.RFC3339 format
CUTOFF_DATE=$(date -u -d "${LOOKBACK} hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-"${LOOKBACK}"H +"%Y-%m-%dT%H:%M:%SZ")

echo "Scribe pre-script: searching Drive for docs matching '${SCRIBE_SEARCH_QUERY}' since ${CUTOFF_DATE}"

# ============================================================
# Repo context — issues, PRs, and doc index
# ============================================================

CLOSED_ISSUES_FILE="${WORK_DIR}/closed-issues.json"
OPEN_PRS_FILE="${WORK_DIR}/open-prs.json"
REPO_DOCS_FILE="${WORK_DIR}/repo-docs-index.json"

# Open issues with bodies (truncated to 500 chars to keep context lean).
# forge_fetch_open_issues_raw paginates all open items. On GitHub the
# response includes PRs (filtered out below); on GitLab it does not.
echo "Fetching open issues from ${SCRIBE_REPO}..."
RAW_PAGINATED_FILE="${WORK_DIR}/raw-paginated-issues.json"
PAGINATION_RC=0
forge_fetch_open_issues_raw "${SCRIBE_REPO}" "${RAW_PAGINATED_FILE}" || PAGINATION_RC=$?
if [[ ${PAGINATION_RC} -ne 0 && ${PAGINATION_RC} -ne 2 ]]; then
  echo "ERROR: failed to fetch open issues from ${SCRIBE_REPO}" >&2
  exit 1
fi

# Count total items from paginated response before filtering.
# Used later for truncation detection.
PAGINATED_TOTAL=$(forge_count_paginated_total "${RAW_PAGINATED_FILE}")

# Filter out PRs (GitHub only; no-op on GitLab), extract fields, truncate bodies
forge_filter_issues_to_backlog "${RAW_PAGINATED_FILE}" "${BACKLOG_FILE}"
rm -f "${RAW_PAGINATED_FILE}"
ISSUE_COUNT=$(jq 'length' "${BACKLOG_FILE}")
echo "Fetched ${ISSUE_COUNT} open issues for backlog context (${PAGINATED_TOTAL} total items including PRs)."

# Recently closed issues (last 50) — helps avoid duplicates and enables
# "this was resolved in #N" references
echo "Fetching recently closed issues..."
forge_list_closed_issues "${SCRIBE_REPO}" "${CLOSED_ISSUES_FILE}" 50
CLOSED_COUNT=$(jq 'length' "${CLOSED_ISSUES_FILE}")
echo "Fetched ${CLOSED_COUNT} recently closed issues."

# Open PRs/MRs — gives awareness of in-flight work so the agent can link
# meeting topics about "the caching PR" to actual PR/MR numbers.
# Uses CONTENTS_TOKEN (coder app) on GitHub; falls back to primary token.
READ_TOKEN="${CONTENTS_TOKEN:-${GH_TOKEN:-${GITLAB_TOKEN:-}}}"
echo "Fetching open pull requests..."
forge_list_open_prs "${SCRIBE_REPO}" "${OPEN_PRS_FILE}" 100 "${READ_TOKEN}"
PR_COUNT=$(jq 'length' "${OPEN_PRS_FILE}")
echo "Fetched ${PR_COUNT} open pull requests."

# Fetch authoritative open-issues count for truncation detection.
# On GitHub, open_issues_count includes PRs — we compare against
# PAGINATED_TOTAL (issues + PRs). On GitLab, it's issues-only and
# PAGINATED_TOTAL is also issues-only, so the comparison holds.
#
# Note: REPO_OPEN_COUNT is fetched in a separate API call after pagination
# completes. Issues or PRs created/closed between the two calls can cause
# small discrepancies. A tolerance of 5 items absorbs typical churn and
# prevents false-positive backlog_truncated=true from API timing.
REPO_OPEN_COUNT=$(forge_get_issue_count "${SCRIBE_REPO}")
TRUNCATION_TOLERANCE=5
if [[ "${PAGINATION_RC}" -eq 2 || "${SCRIBE_BACKLOG_PAGE_CAPPED:-false}" == "true" ]]; then
  BACKLOG_TRUNCATED=true
  OBSERVED_PR_COUNT=$((PAGINATED_TOTAL - ISSUE_COUNT))
  if [[ -n "${REPO_OPEN_COUNT}" ]]; then
    OPEN_ISSUE_TOTAL=$((REPO_OPEN_COUNT - OBSERVED_PR_COUNT))
    [[ "${OPEN_ISSUE_TOTAL}" -lt 0 ]] && OPEN_ISSUE_TOTAL="${ISSUE_COUNT}"
  else
    OPEN_ISSUE_TOTAL="${ISSUE_COUNT}"
  fi
elif [[ -n "${REPO_OPEN_COUNT}" ]]; then
  SHORTFALL=$((REPO_OPEN_COUNT - PAGINATED_TOTAL))
  [[ "${SHORTFALL}" -gt "${TRUNCATION_TOLERANCE}" ]] && BACKLOG_TRUNCATED=true || BACKLOG_TRUNCATED=false
  # Derive issue-only total: subtract observed PR count from API total
  OBSERVED_PR_COUNT=$((PAGINATED_TOTAL - ISSUE_COUNT))
  OPEN_ISSUE_TOTAL=$((REPO_OPEN_COUNT - OBSERVED_PR_COUNT))
  [[ "${OPEN_ISSUE_TOTAL}" -lt 0 ]] && OPEN_ISSUE_TOTAL="${ISSUE_COUNT}"
else
  # API call failed; fall back to fetched count
  OPEN_ISSUE_TOTAL="${ISSUE_COUNT}"
  BACKLOG_TRUNCATED=false
fi

# Repo doc index — ADRs, problem docs, guides. One API call using the
# tree endpoint so the agent can reference docs by path.
echo "Fetching repo doc index..."
forge_get_repo_tree "${SCRIBE_REPO}" "${READ_TOKEN}" "${REPO_DOCS_FILE}"
DOC_PATH_COUNT=$(jq 'length' "${REPO_DOCS_FILE}")
echo "Indexed ${DOC_PATH_COUNT} doc paths from repo tree."

# --- Obtain Drive-scoped access token ---
# The Drive API is a Workspace API that requires its own OAuth scope
# (drive.readonly). The default cloud-platform scope from gcloud doesn't
# cover it. Mint a Drive-scoped token from the SA key using a signed JWT,
# matching what the Go code does with google.CredentialsFromJSON.
# SCRIBE_DRIVE_CREDENTIALS points to the SA key that has been invited to the
# Google Calendar meeting (separate from the Vertex AI SA).
SA_KEY_FILE="${SCRIBE_DRIVE_CREDENTIALS:-${GOOGLE_APPLICATION_CREDENTIALS:-}}"
if [[ -z "${SA_KEY_FILE}" || ! -f "${SA_KEY_FILE}" ]]; then
  echo "ERROR: neither SCRIBE_DRIVE_CREDENTIALS nor GOOGLE_APPLICATION_CREDENTIALS is set or file missing"
  exit 1
fi

SA_EMAIL=$(jq -r '.client_email' "${SA_KEY_FILE}" | tr -d '\n')
echo "::add-mask::${SA_EMAIL}"
NOW=$(date +%s)
EXP=$((NOW + 3600))

JWT_HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
JWT_CLAIMS=$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/drive.readonly","aud":"https://oauth2.googleapis.com/token","exp":%d,"iat":%d}' \
  "${SA_EMAIL}" "${EXP}" "${NOW}" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
JWT_SIGNATURE=$(printf '%s.%s' "${JWT_HEADER}" "${JWT_CLAIMS}" \
  | openssl dgst -sha256 -sign <(jq -r '.private_key' "${SA_KEY_FILE}") \
  | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

JWT_ASSERTION="${JWT_HEADER}.${JWT_CLAIMS}.${JWT_SIGNATURE}"
echo "::add-mask::${JWT_ASSERTION}"

set +e
TOKEN_RESPONSE=$(printf 'grant_type=urn%%3Aietf%%3Aparams%%3Aoauth%%3Agrant-type%%3Ajwt-bearer&assertion=%s' "${JWT_ASSERTION}" \
  | curl -fsSL -X POST https://oauth2.googleapis.com/token \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-binary @- 2>/dev/null)
TOKEN_CURL_RC=$?
set -e

unset JWT_ASSERTION JWT_HEADER JWT_CLAIMS JWT_SIGNATURE

ACCESS_TOKEN=$(printf '%s' "${TOKEN_RESPONSE}" | jq -r '.access_token // empty')
if [[ ${TOKEN_CURL_RC} -ne 0 ]] || [[ -z "${ACCESS_TOKEN}" ]]; then
  echo "ERROR: could not obtain Drive-scoped access token"
  TOKEN_ERROR=$(printf '%s' "${TOKEN_RESPONSE}" | jq -r '.error // .error_description // "unknown error"' 2>/dev/null || echo "non-JSON response")
  echo "Token error: ${TOKEN_ERROR}"
  unset TOKEN_RESPONSE
  exit 1
fi
echo "::add-mask::${ACCESS_TOKEN}"
unset TOKEN_RESPONSE
echo "Obtained Drive-scoped access token"

# --- Search Google Drive for meeting notes ---
ESCAPED_QUERY=$(printf '%s' "${SCRIBE_SEARCH_QUERY}" | sed "s/'/\\\\'/g")
QUERY="name contains '${ESCAPED_QUERY}' and mimeType = 'application/vnd.google-apps.document' and trashed = false and createdTime > '${CUTOFF_DATE}'"

if [[ -n "${SCRIBE_NAME_FILTER:-}" ]]; then
  ESCAPED_FILTER=$(printf '%s' "${SCRIBE_NAME_FILTER}" | sed "s/'/\\\\'/g")
  QUERY="${QUERY} and name contains '${ESCAPED_FILTER}'"
fi

echo "Drive query: ${QUERY}"
ENCODED_QUERY=$(printf '%s' "${QUERY}" | jq -sRr @uri)
DRIVE_URL="https://www.googleapis.com/drive/v3/files?q=${ENCODED_QUERY}&fields=files(id,name,createdTime,modifiedTime,webViewLink)&orderBy=createdTime+desc&pageSize=20&supportsAllDrives=true&includeItemsFromAllDrives=true"

# Do NOT use -f here — we want to see error responses from the API
DRIVE_HTTP_CODE=$(curl -sS -o "${WORK_DIR}/drive-response.json" -w '%{http_code}' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${DRIVE_URL}")

echo "Drive API HTTP status: ${DRIVE_HTTP_CODE}"

if [[ "${DRIVE_HTTP_CODE}" != "200" ]]; then
  echo "ERROR: Drive API returned non-200 status"
  echo "Response body:"
  cat "${WORK_DIR}/drive-response.json"
  exit 1
fi

DOC_COUNT=$(jq '.files | length' "${WORK_DIR}/drive-response.json")
echo "Found ${DOC_COUNT} matching document(s)"

if [[ "${DOC_COUNT}" -gt 0 ]]; then
  jq -r '.files[] | "  \(.name) (created: \(.createdTime))"' "${WORK_DIR}/drive-response.json"
fi

if [[ "${DOC_COUNT}" -eq 0 ]]; then
  echo "No documents found — agent will produce empty result."
  rm -f "${WORK_DIR}/drive-response.json"
  unset ACCESS_TOKEN SA_EMAIL
  # Pack empty notes directory — host_files only supports single files
  tar -czf "${WORK_DIR}/notes.tar.gz" -C "${WORK_DIR}" notes
  jq -n \
    --arg cutoff "${CUTOFF_DATE}" \
    --arg repo "${SCRIBE_REPO}" \
    --argjson doc_count 0 \
    --argjson issue_count "${ISSUE_COUNT}" \
    --argjson open_total "${OPEN_ISSUE_TOTAL}" \
    --argjson truncated "${BACKLOG_TRUNCATED}" \
    --argjson closed_count "${CLOSED_COUNT}" \
    --argjson pr_count "${PR_COUNT}" \
    --argjson doc_path_count "${DOC_PATH_COUNT}" \
    --arg tracker "${FULLSEND_TRACKER}" \
    '{cutoff_date: $cutoff, notes_url: "", repo: $repo, tracker: $tracker, docs_downloaded: $doc_count, backlog_issues: $issue_count, open_issue_total: $open_total, backlog_truncated: $truncated, closed_issues: $closed_count, open_prs: $pr_count, repo_docs: $doc_path_count}' \
    > "${META_FILE}"
  echo "Workspace: ${WORK_DIR}"
  exit 0
fi

MAX_DOC_BYTES=$((2 * 1024 * 1024))  # 2 MiB cap per document

export_doc_with_retry() {
  local doc_id="$1" attempt max_attempts=3
  for attempt in 1 2 3; do
    local http_code body_file="${WORK_DIR}/doc-export-tmp"
    http_code=$(curl -sS -o "${body_file}" -w '%{http_code}' \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "https://www.googleapis.com/drive/v3/files/${doc_id}/export?mimeType=text/plain" \
      2>/dev/null || echo "000")

    if [[ "${http_code}" == "200" ]]; then
      local file_size
      file_size=$(wc -c < "${body_file}")
      if [[ "${file_size}" -gt "${MAX_DOC_BYTES}" ]]; then
        echo "  WARNING: doc ${doc_id} exceeds ${MAX_DOC_BYTES} byte limit (${file_size}), skipping"
        rm -f "${body_file}"
        return 1
      fi
      cat "${body_file}"
      rm -f "${body_file}"
      return 0
    fi

    rm -f "${body_file}"
    if [[ "${http_code}" =~ ^5 ]] && [[ "${attempt}" -lt "${max_attempts}" ]]; then
      local wait=$((1 << (attempt - 1)))
      echo "  WARNING: Drive export returned ${http_code}, retrying in ${wait}s (attempt ${attempt}/${max_attempts})"
      sleep "${wait}"
      continue
    fi

    echo "  WARNING: Drive export failed with HTTP ${http_code} after ${attempt} attempt(s)"
    return 1
  done
  return 1
}

DOC_INDEX=0
DOCS_FAILED=0
while read -r doc; do
  DOC_ID=$(echo "${doc}" | jq -r '.id')
  DOC_NAME=$(echo "${doc}" | jq -r '.name')
  DOC_URL=$(echo "${doc}" | jq -r '.webViewLink')

  echo "  Downloading: ${DOC_NAME}"

  set +e
  RAW_TEXT=$(export_doc_with_retry "${DOC_ID}")
  EXPORT_RC=$?
  set -e
  if [[ ${EXPORT_RC} -ne 0 ]] || [[ -z "${RAW_TEXT}" ]]; then
    echo "  WARNING: could not export doc ${DOC_ID}, skipping"
    DOCS_FAILED=$((DOCS_FAILED + 1))
    continue
  fi

  # --- Suspicious Unicode removal (prompt injection defense) ---
  # Strip tag characters (U+E0000–E007F), zero-width chars, BOM, bidi overrides
  CLEAN_UNICODE=$(printf '%s' "${RAW_TEXT}" \
    | perl -CS -pe 's/[\x{E0000}-\x{E007F}\x{200B}\x{200C}\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}]//g')

  # --- Structural scrubbing (Gemini meeting notes format) ---
  # Gemini notes have: Summary (safe, uses "the team"/"participants"),
  # Next steps (has [Person Name] attributions), and Details (near-verbatim
  # transcript with extensive per-person attributions). The Details section
  # is the primary leakage risk — it's essentially a private transcript
  # with statements attributed to named individuals.
  #
  # Strategy: keep Summary + Next steps (with names stripped), drop Details
  # and everything after it (transcript, timestamps, editor boilerplate).
  #
  # Name scrubbing is format-specific: bracketed Gemini attributions like
  # [John Smith] are replaced, and bullet lines like "- Jane Doe: action"
  # in Next steps are anonymized. Other unbracketed names in prose rely on
  # the agent prompt and public_safe gate for defense-in-depth.
  STRUCTURAL_SCRUB=$(printf '%s' "${CLEAN_UNICODE}" \
    | tr -d '\r' \
    | sed -E '/^Invited /d' \
    | sed -E '/^Attendees:?/d' \
    | sed -E '/^Participants:?$/d' \
    | sed -E 's/^(Organizer|Host|Co-host):?.*/[meeting role line removed]/g' \
    | sed -n '/^Details/,$!p' \
    | sed -E 's/\[[A-Z][a-zA-Z .,-]+\]/[attendee]/g' \
    | sed -E 's/^([[:space:]]*[-*][[:space:]]*)[A-Z][a-zA-Z]+ [A-Z][a-zA-Z .-]+:/\1[attendee]:/g')

  # --- PII pattern scrubbing ---
  # Ordered: specific patterns first, generic last (matches Go sanitizer.go)
  SCRUBBED=$(echo "${STRUCTURAL_SCRUB}" \
    | sed -E 's/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/[REDACTED]/g' \
    | sed -E 's/\b(\+?1[-. ]?)?\(?\d{3}\)?[-. ]?\d{3}[-. ]?\d{4}\b/[REDACTED]/g' \
    | sed -E 's/\+\d{1,3}[-. ]?\d{4,14}\b/[REDACTED]/g' \
    | sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/[REDACTED]/g' \
    | sed -E 's/\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b/[REDACTED]/g' \
    | sed -E 's/\b([0-9][ -]?){13,19}\b/[REDACTED]/g' \
    | sed -E 's/\b(AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b/[REDACTED]/g' \
    | sed -E 's/[Aa][Ww][Ss].?[Ss][Ee][Cc][Rr][Ee][Tt].?([Aa][Cc][Cc][Ee][Ss][Ss])?.?[Kk][Ee][Yy][[:space:]]*[:=][[:space:]]*[A-Za-z0-9\/+=]{40}/[REDACTED]/g' \
    | sed -E 's/\b(ghp|gho|ghs|ghr)_[A-Za-z0-9_]{36,255}\b/[REDACTED]/g' \
    | sed -E 's|https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+|[REDACTED]|g' \
    | sed -E 's/-----BEGIN[[:space:]]+(RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----.*/[REDACTED]/g' \
    | sed -E 's/[Pp][Rr][Ii][Vv][Aa][Tt][Ee]_[Kk][Ee][Yy]_[Ii][Dd][[:space:]]*[:=][[:space:]]*['"'"'"]?[a-f0-9]{40}['"'"'"]?/[REDACTED]/g' \
    | sed -E 's/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/[REDACTED]/g' \
    | sed -E 's/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Bb][Ee][Aa][Rr][Ee][Rr])[[:space:]]*[:=][[:space:]]*['"'"'"]?[A-Za-z0-9_.~+\/-]{20,}['"'"'"]?/[REDACTED]/g')

  echo "${SCRUBBED}" > "${NOTES_DIR}/doc-${DOC_INDEX}.txt"
  echo "${DOC_URL}" > "${NOTES_DIR}/doc-${DOC_INDEX}.url"

  DOC_INDEX=$((DOC_INDEX + 1))
done < <(jq -c '.files[]' "${WORK_DIR}/drive-response.json")

if [[ "${DOCS_FAILED}" -gt 0 ]]; then
  echo "WARNING: ${DOCS_FAILED} doc(s) failed to export (continued with remaining)"
fi

NOTES_URL=""
if [[ -f "${NOTES_DIR}/doc-0.url" ]]; then
  NOTES_URL=$(cat "${NOTES_DIR}/doc-0.url")
fi

jq -n \
  --arg cutoff "${CUTOFF_DATE}" \
  --arg notes_url "${NOTES_URL}" \
  --arg repo "${SCRIBE_REPO}" \
  --argjson doc_count "${DOC_COUNT}" \
  --argjson issue_count "${ISSUE_COUNT}" \
  --argjson open_total "${OPEN_ISSUE_TOTAL}" \
  --argjson truncated "${BACKLOG_TRUNCATED}" \
  --argjson closed_count "${CLOSED_COUNT}" \
  --argjson pr_count "${PR_COUNT}" \
  --argjson doc_path_count "${DOC_PATH_COUNT}" \
  --arg tracker "${FULLSEND_TRACKER}" \
  '{
    cutoff_date: $cutoff,
    notes_url: $notes_url,
    repo: $repo,
    tracker: $tracker,
    docs_downloaded: $doc_count,
    backlog_issues: $issue_count,
    open_issue_total: $open_total,
    backlog_truncated: $truncated,
    closed_issues: $closed_count,
    open_prs: $pr_count,
    repo_docs: $doc_path_count
  }' > "${META_FILE}"

# Pack notes directory into a tarball — fullsend host_files only supports
# single files, not directories (UploadFile vs UploadDir).
tar -czf "${WORK_DIR}/notes.tar.gz" -C "${WORK_DIR}" notes

# Cleanup: remove Drive API response (contains doc IDs and metadata)
rm -f "${WORK_DIR}/drive-response.json" "${WORK_DIR}/doc-export-tmp"
unset ACCESS_TOKEN SA_EMAIL

echo "Pre-scribe complete. ${DOC_COUNT} docs scraped, ${ISSUE_COUNT} issues + ${CLOSED_COUNT} closed + ${PR_COUNT} PRs + ${DOC_PATH_COUNT} doc paths."
echo "Workspace: ${WORK_DIR}"
