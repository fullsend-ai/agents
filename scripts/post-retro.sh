#!/usr/bin/env bash
# GENERATED from post-retro.src.sh — DO NOT EDIT. Run: make script-build
# post-retro.sh — File issues from retro agent proposals and post summary.
#
# Runs on the host after sandbox cleanup. Working directory is the fullsend
# run output directory.
#
# Required env vars:
#   ORIGINATING_URL — HTML URL of the originating PR or issue
#   FULLSEND_FORGE  — "github" or "gitlab"
#
# Optional env vars:
#   FULLSEND_TRACKER    — "github", "gitlab", or "jira" (defaults to FULLSEND_FORGE)
#   RETRO_MODE          — "all" (default), "summary_only", or "issues_only"
#   RETRO_JIRA_PROJECT  — Jira project key for created issues (when FULLSEND_TRACKER=jira)
#   FULLSEND_DIR        — .fullsend directory (when FULLSEND_TRACKER=jira)
#
# Forge-specific token env vars:
#   GH_TOKEN      — GitHub token (when FULLSEND_FORGE=github)
#   GITLAB_TOKEN  — GitLab token (when FULLSEND_FORGE=gitlab)
#   JIRA_TOKEN    — Jira token (when FULLSEND_TRACKER=jira)
#
# The agent writes its result to output/agent-result.json (relative to
# the iteration directory). This script finds the most recent iteration's output.

set -euo pipefail

: "${ORIGINATING_URL:?ORIGINATING_URL is required}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retro-ops.lib.sh
# BEGIN bundled: lib/retro-ops.lib.sh
# shellcheck shell=bash
# retro-ops.lib.sh — Forge-dispatch wrapper for retro operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${RETRO_OPS_SH_LOADED:-}" ]] && return 0
RETRO_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-retro-ops.lib.sh
# shellcheck shell=bash
# github-retro-ops.lib.sh — GitHub forge operations for retro scripts.
#
# Bundled into pre-retro.sh and post-retro.sh via retro-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by forge_parse_originating_url):
#   ORIGINATING_REPO   — owner/repo (e.g., "org/repo")
#   ORIGINATING_NUMBER — issue or PR number
#
# Expected env vars:
#   ORIGINATING_URL — HTML URL of the originating PR or issue
#   GH_TOKEN        — GitHub token with issues:write and pull_requests:write scope

[[ -n "${GITHUB_RETRO_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_RETRO_OPS_SH_LOADED=1

# --- URL handling ---

_forge_validate_originating_url() {
  if [[ ! "${ORIGINATING_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/(issues|pull)/[0-9]+$ ]]; then
    echo "ERROR: ORIGINATING_URL does not match expected pattern: $(_gha_sanitize "${ORIGINATING_URL}")" >&2
    return 1
  fi
}
forge_validate_originating_url() {
  _forge_validate_originating_url
}

_forge_parse_originating_url() {
  # shellcheck disable=SC2034 # ORIGINATING_REPO consumed by callers after function returns
  ORIGINATING_REPO=$(echo "${ORIGINATING_URL}" | sed -E 's#https://github.com/##; s#/(issues|pull)/.*##')
  # shellcheck disable=SC2034 # ORIGINATING_NUMBER consumed by callers after function returns
  ORIGINATING_NUMBER=$(basename "${ORIGINATING_URL}")
}
forge_parse_originating_url() {
  _forge_parse_originating_url
}

# --- Token handling ---

_forge_mask_token() {
  if [[ -n "${GITHUB_ACTIONS:-}" && -n "${GH_TOKEN:-}" ]]; then
    echo "::add-mask::${GH_TOKEN}"
  fi
}
forge_mask_token() {
  _forge_mask_token
}

_forge_require_token() {
  : "${GH_TOKEN:?GH_TOKEN is required}"
}
forge_require_token() {
  _forge_require_token
}

# --- Config workspace ---

forge_get_config_workspace() {
  echo "${GITHUB_WORKSPACE:-/tmp}"
}

# --- Comment limits ---

_forge_get_comment_max_len() {
  echo "65000"
}
forge_get_comment_max_len() {
  _forge_get_comment_max_len
}

# --- Labels ---

forge_create_label() {
  local repo="$1" name="$2" description="$3" color="$4"
  gh label create "${name}" --repo "${repo}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

# --- Issues ---

forge_create_issue() {
  local repo="$1" title="$2" body="$3" label="$4"
  gh issue create \
    --repo "${repo}" \
    --title "${title}" \
    --body "${body}" \
    --label "${label}" 2>&1
}

# --- Comments ---

_forge_post_comment() {
  local repo="$1" number="$2" body="$3"
  jq -nc --arg body "${body}" '{body: $body}' | gh api \
    "repos/${repo}/issues/${number}/comments" \
    --input - 2>&1
}
forge_post_comment() {
  _forge_post_comment "$@"
}
# END bundled: lib/github-retro-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-retro-ops.lib.sh
# shellcheck shell=bash
# gitlab-retro-ops.lib.sh — GitLab forge operations for retro scripts.
#
# Bundled into pre-retro.sh and post-retro.sh via retro-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by forge_parse_originating_url):
#   GITLAB_HOST             — API host (e.g., "gitlab.com")
#   ORIGINATING_REPO        — plain project path (e.g., "group/project")
#   ORIGINATING_NUMBER      — issue IID or MR IID
#   ORIGINATING_RESOURCE    — "issues" or "merge_requests"
#
# Expected env vars:
#   ORIGINATING_URL — HTML URL of the originating MR or issue
#   GITLAB_TOKEN    — GitLab personal/project access token

[[ -n "${GITLAB_RETRO_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_RETRO_OPS_SH_LOADED=1

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
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call forge_parse_originating_url first" >&2
    return 1
  fi
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@"
}

# --- URL handling ---

_forge_validate_originating_url() {
  if [[ ! "${ORIGINATING_URL}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+){2,}/-/(issues|merge_requests)/[0-9]+$ ]]; then
    echo "ERROR: ORIGINATING_URL does not match expected GitLab pattern: $(_gha_sanitize "${ORIGINATING_URL}")" >&2
    return 1
  fi
  local host
  host=$(echo "${ORIGINATING_URL}" | sed -E 's#^https://([^/:]+)/.*#\1#')
  _validate_gitlab_host "${host}" || return 1
}
forge_validate_originating_url() {
  _forge_validate_originating_url
}

_forge_parse_originating_url() {
  # Extract host, project path, resource type, and number from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/issues/42
  # e.g., https://gitlab.com/group/project/-/merge_requests/10
  # shellcheck disable=SC2034 # GITLAB_HOST consumed by _gitlab_api and callers
  GITLAB_HOST=$(echo "${ORIGINATING_URL}" | sed -E 's#^https://([^/:]+)/.*#\1#')
  # shellcheck disable=SC2034 # ORIGINATING_REPO consumed by callers and is_target_allowed
  ORIGINATING_REPO=$(echo "${ORIGINATING_URL}" | sed -E 's#^https://[^/]+/(.+)/-/(issues|merge_requests)/[0-9]+$#\1#')
  # shellcheck disable=SC2034 # ORIGINATING_NUMBER consumed by callers after function returns
  ORIGINATING_NUMBER=$(basename "${ORIGINATING_URL}")
  # Detect resource type: issues or merge_requests
  if [[ "${ORIGINATING_URL}" == *"/-/merge_requests/"* ]]; then
    # shellcheck disable=SC2034 # ORIGINATING_RESOURCE consumed by forge_post_comment
    ORIGINATING_RESOURCE="merge_requests"
  else
    # shellcheck disable=SC2034 # ORIGINATING_RESOURCE consumed by forge_post_comment
    ORIGINATING_RESOURCE="issues"
  fi
}
forge_parse_originating_url() {
  _forge_parse_originating_url
}

# --- Token handling ---

_forge_mask_token() {
  # ::add-mask:: is GHA-only; on non-GHA runners the echo would leak the token.
  if [[ -n "${GITHUB_ACTIONS:-}" && -n "${GITLAB_TOKEN:-}" ]]; then
    echo "::add-mask::${GITLAB_TOKEN}"
  fi
}
forge_mask_token() {
  _forge_mask_token
}

_forge_require_token() {
  : "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
}
forge_require_token() {
  _forge_require_token
}

# --- Config workspace ---

forge_get_config_workspace() {
  echo "${CI_PROJECT_DIR:-/tmp}"
}

# --- Comment limits ---

_forge_get_comment_max_len() {
  echo "1000000"
}
forge_get_comment_max_len() {
  _forge_get_comment_max_len
}

# --- Labels ---

forge_create_label() {
  local repo="$1" name="$2" description="$3" color="$4"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api POST "/projects/${repo_encoded}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${color}" > /dev/null 2>/dev/null || true
}

# --- Issues ---

forge_create_issue() {
  local repo="$1" title="$2" body="$3" label="$4"
  local repo_encoded body_file
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  printf '%s' "${body}" > "${body_file}"
  local response
  response=$(_gitlab_api POST "/projects/${repo_encoded}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description@${body_file}" \
    --data-urlencode "labels=${label}" 2>&1) || {
    rm -f "${body_file}"
    echo "GitLab API error: issue creation failed in ${repo}: $(_gha_sanitize "${response}")"
    return 1
  }
  rm -f "${body_file}"
  local url
  url=$(echo "${response}" | jq -r '.web_url')
  if [[ -z "${url}" || "${url}" == "null" ]]; then
    echo "GitLab API error: unexpected response from issue creation in ${repo}"
    return 1
  fi
  echo "${url}"
}

# --- Comments ---

# Requires ORIGINATING_RESOURCE (set by forge_parse_originating_url) to
# resolve the correct GitLab notes endpoint (merge_requests vs issues).
_forge_post_comment() {
  : "${ORIGINATING_RESOURCE:?forge_parse_originating_url must be called before forge_post_comment}"
  local repo="$1" number="$2" body="$3"
  local repo_encoded body_file rc=0
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  printf '%s' "${body}" > "${body_file}"
  _gitlab_api POST "/projects/${repo_encoded}/${ORIGINATING_RESOURCE}/${number}/notes" \
    --data-urlencode "body@${body_file}" 2>&1 || rc=$?
  rm -f "${body_file}"
  return "${rc}"
}
forge_post_comment() {
  _forge_post_comment "$@"
}
# END bundled: lib/gitlab-retro-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — set FULLSEND_FORGE to github or gitlab" >&2
    exit 1
    ;;
esac

FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE}}"

case "${FULLSEND_TRACKER}" in
  "${FULLSEND_FORGE}") ;;
  jira)
# BEGIN bundled: lib/jira-retro-ops.lib.sh
# shellcheck shell=bash
# jira-retro-ops.lib.sh — Jira Cloud tracker operations for retro scripts.
#
# Bundled into pre-retro.sh and post-retro.sh via retro-ops.lib.sh, which
# sources this file AFTER the GitHub/GitLab forge library when
# FULLSEND_TRACKER=jira.
#
# Allows retro to run against Jira-originated work items and/or GitHub PRs
# or GitLab MRs associated with Jira work, filing proposal issues into
# an operator-configured Jira project (RETRO_JIRA_PROJECT) with idempotency
# protection and summary comments.
#
# All writes happen host-side in post-retro.sh with operator-provided
# credentials; the sandbox never receives the Jira token.
#
# Jira Cloud only: JIRA_BASE_URL must be https://<site>.atlassian.net.
#
# Expected env vars:
#   JIRA_BASE_URL          — Jira Cloud base URL (https://<site>.atlassian.net)
#   JIRA_TOKEN             — Jira API token
#   FULLSEND_DIR           — .fullsend directory whose config.yaml holds
#                            tracker.jira, for fullsend issues shell-outs
#   RETRO_JIRA_PROJECT     — Jira project key for proposal issues (e.g. "PROJ")
#
# Optional env vars:
#   JIRA_USER_EMAIL        — bot-user email. When set, requests use Basic
#                            auth with email and token; when unset or empty,
#                            Bearer auth with a service-account token.
#   JIRA_API_URL           — REST API gateway base URL. Falls back to JIRA_BASE_URL.
#   RETRO_JIRA_ISSUE_TYPE  — issue type name for created issues (default: "Task")
#   RETRO_JIRA_LABELS      — comma-separated allowlist of labels that retro may
#                            apply to Jira issues (default: "ready-for-triage")
#   RETRO_JIRA_MAX_PAGES   — maximum pages fetched per paginated Jira read (default: 50)
#   RETRO_MODE             — "all" (default), "summary_only", or "issues_only"

[[ -n "${JIRA_RETRO_OPS_SH_LOADED:-}" ]] && return 0
JIRA_RETRO_OPS_SH_LOADED=1

RETRO_JIRA_PROJECT="${RETRO_JIRA_PROJECT:-${JIRA_PROJECT:-}}"
RETRO_MODE="${RETRO_MODE:-all}"
if [[ "${RETRO_MODE}" != "summary_only" ]]; then
  : "${JIRA_TOKEN:?JIRA_TOKEN must be set}"
  : "${JIRA_BASE_URL:?JIRA_BASE_URL must be set}"
  : "${RETRO_JIRA_PROJECT:?RETRO_JIRA_PROJECT must be set}"
fi

# shellcheck source=jira-auth.lib.sh
# BEGIN bundled: lib/jira-auth.lib.sh
# shellcheck shell=bash
# jira-auth.lib.sh — Jira credential-mode selection for host-side scripts.
#
# Shared by the Jira triage and scribe ops libraries and post-code.sh, and
# bundled into each script that sources it. Two credential modes
# (fullsend#9007):
#
#   token + email — bot user: Basic auth with email:token
#   token only    — service account: Bearer auth with the token
#
# An email that is empty or only whitespace counts as absent. A harness
# that maps an unset FULLSEND_JIRA_EMAIL to JIRA_USER_EMAIL yields an empty
# string, and that must select Bearer, never an empty-user Basic header.
#
# Every helper takes the token and email as arguments, so callers that
# withhold the credentials from their environment can pass saved copies.

[[ -n "${JIRA_AUTH_SH_LOADED:-}" ]] && return 0
JIRA_AUTH_SH_LOADED=1

# Print the email with surrounding whitespace removed. Empty output means
# no email, which selects Bearer auth.
#
# Usage: jira_auth_email <email>
jira_auth_email() {
  local email="$1"
  email="${email#"${email%%[![:space:]]*}"}"
  email="${email%"${email##*[![:space:]]}"}"
  printf '%s' "${email}"
}

# Run curl with the Authorization for the selected mode, followed by the
# caller's arguments. Fails without calling curl when the token is empty.
#
# Usage: jira_auth_curl <token> <email> [curl args...]
jira_auth_curl() {
  local token="$1"
  local email
  email="$(jira_auth_email "$2")"
  shift 2
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    curl --user "${email}:${token}" "$@"
  else
    curl --oauth2-bearer "${token}" "$@"
  fi
}

# Run the fullsend CLI with the Jira credentials it reads from its
# environment: FULLSEND_JIRA_TOKEN always, FULLSEND_JIRA_EMAIL only for a
# bot user. In Bearer mode an inherited FULLSEND_JIRA_EMAIL is removed, so
# the CLI cannot pick Basic auth. The values go through the environment,
# never the command line.
#
# Usage: jira_auth_fullsend <fullsend-bin> <token> <email> [cli args...]
jira_auth_fullsend() {
  local bin="$1"
  local token="$2"
  local email
  email="$(jira_auth_email "$3")"
  shift 3
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    FULLSEND_JIRA_TOKEN="${token}" FULLSEND_JIRA_EMAIL="${email}" "${bin}" "$@"
  else
    (
      unset FULLSEND_JIRA_EMAIL
      FULLSEND_JIRA_TOKEN="${token}" "${bin}" "$@"
    )
  fi
}
# END bundled: lib/jira-auth.lib.sh

if [[ -n "${JIRA_BASE_URL:-}" ]]; then
  while [[ "${JIRA_BASE_URL}" == */ ]]; do
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"
  done
  if [[ ! "${JIRA_BASE_URL}" =~ ^https://[a-zA-Z0-9-]+\.atlassian\.net$ ]]; then
    echo "ERROR: JIRA_BASE_URL must be a Jira Cloud URL (https://<site>.atlassian.net)" >&2
    exit 1
  fi
fi

RETRO_JIRA_API_BASE="${JIRA_API_URL:-${JIRA_BASE_URL:-}}"
if [[ -n "${RETRO_JIRA_API_BASE}" ]]; then
  while [[ "${RETRO_JIRA_API_BASE}" == */ ]]; do
    RETRO_JIRA_API_BASE="${RETRO_JIRA_API_BASE%/}"
  done
  if [[ "${RETRO_JIRA_API_BASE}" != https://* ]]; then
    echo "ERROR: JIRA_API_URL must start with https://" >&2
    exit 1
  fi
fi

if [[ -n "${RETRO_JIRA_PROJECT}" && ! "${RETRO_JIRA_PROJECT}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
  echo "ERROR: RETRO_JIRA_PROJECT must be a Jira project key (e.g. PROJ)" >&2
  exit 1
fi

RETRO_JIRA_ISSUE_TYPE="${RETRO_JIRA_ISSUE_TYPE:-Task}"
RETRO_JIRA_LABELS="${RETRO_JIRA_LABELS:-ready-for-triage}"
RETRO_JIRA_MAX_PAGES="${RETRO_JIRA_MAX_PAGES:-50}"

_retro_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    "${RETRO_JIRA_API_BASE}/rest/api/3${endpoint}" \
    "$@"
}

_retro_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file raw http_code body
  err_file=$(mktemp)
  raw=$(jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${RETRO_JIRA_API_BASE}/rest/api/3${endpoint}" \
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

_retro_jql_quote() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '"%s"' "${val}"
}

_retro_jira_search_paginated() {
  local jql="$1" fields_json="$2" output_file="$3"
  local token="" page payload response is_last
  : > "${output_file}"
  for ((page = 1; page <= RETRO_JIRA_MAX_PAGES; page++)); do
    payload=$(jq -cn --arg jql "${jql}" --argjson fields "${fields_json}" --arg tok "${token}" \
      '{jql: $jql, fields: $fields, maxResults: 100} + (if $tok != "" then {nextPageToken: $tok} else {} end)')
    response=$(_retro_jira_api POST "/search/jql" --data "${payload}") || {
      echo "ERROR: Jira JQL search failed" >&2
      return 1
    }
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
  echo "WARNING: Jira search stopped after ${RETRO_JIRA_MAX_PAGES} pages; results are truncated" >&2
  return 2
}

_retro_jira_filter_labels() {
  local raw="$1"
  jq -cn \
    --arg raw "${raw}" \
    --arg allowlist "${RETRO_JIRA_LABELS:-ready-for-triage}" '
    def parse_list:
      if (type == "array") then .
      elif (type == "string") then [split(",")[] | gsub("^\\s+|\\s+$"; "")]
      else [] end;
    def parse_raw:
      ($raw | try fromjson catch $raw) | parse_list;
    def parse_allowlist:
      $allowlist | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(test("^[A-Za-z0-9._-]{1,64}$")));
    (parse_allowlist) as $allowed |
    [parse_raw[]?
      | select(type == "string")
      | gsub("^\\s+|\\s+$"; "")
      | select(test("^[A-Za-z0-9._-]{1,64}$"))
      | select(. as $item | $allowed | index($item))
    ] | reduce .[] as $item ([]; if index($item) then . else . + [$item] end) | .[0:10]
  '
}

_retro_jira_add_labels() {
  local key="$1" labels="$2"
  local labels_json ops
  labels_json=$(_retro_jira_filter_labels "${labels}")
  if [[ "$(printf '%s' "${labels_json}" | jq 'length')" -eq 0 ]]; then
    return 0
  fi
  ops=$(printf '%s' "${labels_json}" | jq '{update:{labels:[.[] | {add:.}]}}')
  _retro_jira_api_with_status PUT "/issue/${key}" --data "${ops}" > /dev/null
}

_retro_jira_createmeta_all() {
  local endpoint="$1" start=0 page resp count total last
  local items_file
  items_file=$(mktemp)
  printf '[]' > "${items_file}"
  for ((page = 1; page <= RETRO_JIRA_MAX_PAGES; page++)); do
    resp=$(_retro_jira_api GET "${endpoint}?maxResults=200&startAt=${start}") || { rm -f "${items_file}"; return 1; }
    count=$(printf '%s' "${resp}" | jq -r '(.issueTypes // .values // .fields // []) | length') || { rm -f "${items_file}"; return 1; }
    if printf '%s' "${resp}" | jq -c '(.issueTypes // .values // .fields // []) | map(del(.allowedValues))' \
      | jq -sc '.[0] + .[1]' "${items_file}" - > "${items_file}.tmp" \
      && mv "${items_file}.tmp" "${items_file}"; then
      :
    else
      rm -f "${items_file}" "${items_file}.tmp"
      return 1
    fi
    total=$(printf '%s' "${resp}" | jq -r '.total // empty')
    last=$(printf '%s' "${resp}" | jq -r 'if has("isLast") then (.isLast | tostring) else "absent" end')
    start=$((start + count))
    if [[ "${count}" -eq 0 || "${last}" == "true" ]] \
      || [[ -z "${total}" && "${last}" == "absent" ]] \
      || [[ -n "${total}" && "${start}" -ge "${total}" ]]; then
      cat "${items_file}"
      rm -f "${items_file}"
      return 0
    fi
  done
  rm -f "${items_file}"
  echo "ERROR: Jira create metadata exceeds ${RETRO_JIRA_MAX_PAGES} pages" >&2
  return 1
}

tracker_validate_create() {
  local types type_id meta missing
  if ! fullsend issues create --help >/dev/null 2>&1; then
    echo "ERROR: 'fullsend issues create' is not available — upgrade fullsend to a version that includes the config-backed Jira commands (fullsend#9078)" >&2
    return 1
  fi
  types=$(_retro_jira_createmeta_all "/issue/createmeta/${RETRO_JIRA_PROJECT}/issuetypes") || {
    echo "ERROR: cannot read create metadata for Jira project ${RETRO_JIRA_PROJECT} (missing project or no create permission)" >&2
    return 1
  }
  type_id=$(printf '%s' "${types}" | jq -r --arg name "${RETRO_JIRA_ISSUE_TYPE}" \
    '[.[] | select(.name == $name)][0].id // empty')
  if [[ -z "${type_id}" ]]; then
    echo "ERROR: issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' is not available in Jira project ${RETRO_JIRA_PROJECT}" >&2
    return 1
  fi
  meta=$(_retro_jira_createmeta_all "/issue/createmeta/${RETRO_JIRA_PROJECT}/issuetypes/${type_id}") || {
    echo "ERROR: cannot read create fields for issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' in Jira project ${RETRO_JIRA_PROJECT}" >&2
    return 1
  }
  missing=$(printf '%s' "${meta}" | jq -r '
    [.[]
      | select(.required == true and (.hasDefaultValue // false) == false)
      | select((.fieldId // .key) as $f | ["project","issuetype","summary","description"] | index($f) | not)
      | (.fieldId // .key)] | join(", ")')
  if [[ -n "${missing}" ]]; then
    echo "ERROR: Jira project ${RETRO_JIRA_PROJECT} requires fields retro does not set: $(_gha_sanitize "${missing}")" >&2
    return 1
  fi
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "description")' >/dev/null; then
    echo "ERROR: issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' in Jira project ${RETRO_JIRA_PROJECT} has no Description field on its create screen" >&2
    return 1
  fi
  RETRO_JIRA_LABELS_AVAILABLE=true
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "labels")' >/dev/null; then
    RETRO_JIRA_LABELS_AVAILABLE=false
    echo "WARNING: issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' in Jira project ${RETRO_JIRA_PROJECT} has no Labels field on its create screen; labels will be omitted" >&2
  fi
}

tracker_find_existing_issue() {
  local title="$1" raw_file jql terms match rc=0
  terms=$(printf '%s' "${title}" | jq -Rr '[scan("[\\p{L}\\p{N}]+")] | join(" ")') || return 1
  if [[ -z "${terms}" ]]; then
    echo "ERROR: Jira duplicate check has no searchable terms in the issue title" >&2
    return 1
  fi
  raw_file=$(mktemp)
  jql="project = $(_retro_jql_quote "${RETRO_JIRA_PROJECT}") AND summary ~ $(_retro_jql_quote "$(_retro_jql_quote "${terms}")")"
  _retro_jira_search_paginated "${jql}" '["summary"]' "${raw_file}" || rc=$?
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

forge_create_issue() {
  local repo="$1" title="$2" body="$3" labels="${4:-ready-for-triage}"
  if [[ -z "${body}" || "${body}" == "-" ]]; then
    body=$(cat)
  fi
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: forge_create_issue: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  local response key url
  response=$(printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    issues create \
    --tracker jira \
    --fullsend-dir "${FULLSEND_DIR}" \
    --project "${RETRO_JIRA_PROJECT}" \
    --type "${RETRO_JIRA_ISSUE_TYPE}" \
    --title "${title}" \
    --body -) || {
    echo "ERROR: forge_create_issue: fullsend issues create failed in project ${RETRO_JIRA_PROJECT}" >&2
    return 1
  }
  key=$(printf '%s' "${response}" | jq -r '.key // empty' 2>/dev/null)
  url=$(printf '%s' "${response}" | jq -r '.url // empty' 2>/dev/null)
  if [[ -z "${key}" ]] || [[ ! "${key}" =~ ^${RETRO_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: forge_create_issue: fullsend issues create returned no valid issue key" >&2
    return 1
  fi
  local label_failed=false
  if [[ "${RETRO_JIRA_LABELS_AVAILABLE:-true}" == "true" ]] && [[ -n "${labels}" ]]; then
    if ! _retro_jira_add_labels "${key}" "${labels}"; then
      echo "WARNING: forge_create_issue: failed to add labels to ${key} (issue created without labels)" >&2
      label_failed=true
    fi
  fi
  if [[ -n "${url}" ]]; then
    echo "${url}"
  else
    echo "${JIRA_BASE_URL}/browse/${key}"
  fi
  [[ "${label_failed}" == "true" ]] && return 2
  return 0
}

forge_create_label() {
  # Jira labels are ad-hoc strings and do not require pre-creation.
  return 0
}

forge_issue_url_base() {
  echo "${JIRA_BASE_URL}/browse"
}

forge_normalize_labels() {
  local labels="$1"
  printf '%s' "$(_retro_jira_filter_labels "${labels}")" | jq -r 'join(",")'
}

# --- Originating URL handling and comments ---

forge_validate_originating_url() {
  if [[ "${ORIGINATING_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    local host
    host=$(echo "${ORIGINATING_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
    case "${host}" in
      *.atlassian.net)
        : "${JIRA_BASE_URL:?JIRA_BASE_URL must be set}"
        if [[ "https://${host}" != "${JIRA_BASE_URL}" ]]; then
          echo "ERROR: ORIGINATING_URL Jira host ('${host}') does not match JIRA_BASE_URL ('${JIRA_BASE_URL}')" >&2
          return 1
        fi
        return 0
        ;;
      *)
        echo "ERROR: ORIGINATING_URL Jira host '${host}' is not in the allowed host list (*.atlassian.net)" >&2
        return 1
        ;;
    esac
  fi
  if declare -f _forge_validate_originating_url >/dev/null 2>&1; then
    _forge_validate_originating_url
  else
    echo "ERROR: ORIGINATING_URL does not match expected pattern: $(_gha_sanitize "${ORIGINATING_URL}")" >&2
    return 1
  fi
}

forge_parse_originating_url() {
  if [[ "${ORIGINATING_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    # shellcheck disable=SC2034 # consumed by post-retro
    JIRA_ORIGINATING="true"
    local issue_key
    issue_key=$(echo "${ORIGINATING_URL}" | sed -E 's|.*/browse/||')
    # shellcheck disable=SC2034 # consumed by post-retro
    ORIGINATING_REPO="${issue_key%-*}"
    # shellcheck disable=SC2034 # consumed by post-retro
    ORIGINATING_NUMBER="${issue_key}"
  else
    # shellcheck disable=SC2034 # consumed by post-retro
    JIRA_ORIGINATING="false"
    if declare -f _forge_parse_originating_url >/dev/null 2>&1; then
      _forge_parse_originating_url
    fi
  fi
}

_retro_jira_post_comment() {
  local repo="$1" number="$2" body="$3"
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  if [[ -z "${JIRA_TOKEN:-}" ]]; then
    echo "ERROR: JIRA_TOKEN must be set to post comments to Jira" >&2
    return 1
  fi
  local num="${number##*-}"
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${repo}" --number "${num}" \
    --marker "<!-- fullsend:retro-agent -->" --result -
}

forge_post_comment() {
  local repo="$1" number="$2" body="$3"
  if [[ "${JIRA_ORIGINATING:-false}" == "true" ]]; then
    _retro_jira_post_comment "${repo}" "${number}" "${body}"
  elif declare -f _forge_post_comment >/dev/null 2>&1; then
    _forge_post_comment "${repo}" "${number}" "${body}"
  else
    echo "ERROR: no forge_post_comment defined" >&2
    return 1
  fi
}

forge_require_token() {
  local jira_origin="${JIRA_ORIGINATING:-false}"
  if [[ "${jira_origin}" != "true" && "${ORIGINATING_URL:-}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    jira_origin="true"
  fi
  if [[ "${RETRO_MODE}" != "summary_only" || "${jira_origin}" == "true" ]]; then
    : "${JIRA_TOKEN:?JIRA_TOKEN must be set}"
  fi
  if [[ "${jira_origin}" == "true" ]]; then
    return 0
  fi
  if declare -f _forge_require_token >/dev/null 2>&1; then
    _forge_require_token
  fi
}

forge_mask_token() {
  local jira_origin="${JIRA_ORIGINATING:-false}"
  if [[ "${jira_origin}" != "true" && "${ORIGINATING_URL:-}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    jira_origin="true"
  fi
  if [[ "${jira_origin}" != "true" ]] && declare -f _forge_mask_token >/dev/null 2>&1; then
    _forge_mask_token
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" && -n "${JIRA_TOKEN:-}" ]]; then
    printf '::add-mask::%s\n' "$(printf '%s' "${JIRA_TOKEN}" | tr -d '\n\r')"
  fi
}

forge_get_comment_max_len() {
  if [[ "${JIRA_ORIGINATING:-false}" == "true" ]]; then
    echo "32768"
  elif declare -f _forge_get_comment_max_len >/dev/null 2>&1; then
    _forge_get_comment_max_len
  else
    echo "65000"
  fi
}
# END bundled: lib/jira-retro-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_TRACKER: '$(_gha_sanitize "${FULLSEND_TRACKER}")' — must be 'jira' or match FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/retro-ops.lib.sh

forge_validate_originating_url
forge_parse_originating_url

forge_require_token
forge_mask_token

# Find the retro result JSON — prefer the validated iteration when set.
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
    echo "ERROR: FULLSEND_VALIDATED_ITERATION_DIR is set but contains neither agent-result.json nor result.json" >&2
    exit 1
  fi
else
  # Backward compatibility: scan iteration-N/ subdirectories for the last one's output.
  RESULT_FILE=""
  for dir in iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      RESULT_FILE="${dir}/agent-result.json"
    fi
  done
fi

if [[ -z "${RESULT_FILE}" ]]; then
  echo "ERROR: agent-result.json not found in any iteration output directory" >&2
  exit 1
fi

echo "Reading retro result from: ${RESULT_FILE}"

# Validate JSON is parseable.
if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON" >&2
  exit 1
fi

echo "Originating: ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}"

RETRO_MODE="${RETRO_MODE:-all}"
case "${RETRO_MODE}" in
  all|summary_only|issues_only) ;;
  *)
    echo "ERROR: RETRO_MODE must be 'all', 'summary_only', or 'issues_only' (got: ${RETRO_MODE})" >&2
    exit 1
    ;;
esac
echo "Mode: ${RETRO_MODE}"

# Read the allowlist from config.yaml. The config repo is checked out
# at the forge-specific workspace directory by the reusable workflow.
CONFIG_WORKSPACE="$(forge_get_config_workspace)"
CONFIG_FILE="${CONFIG_WORKSPACE}/config.yaml"
if [[ ! -f "${CONFIG_FILE}" && ! -f "${CONFIG_WORKSPACE}/config.base.yaml" ]]; then
  # Per-repo mode: config is under .fullsend/
  CONFIG_FILE="${CONFIG_WORKSPACE}/.fullsend/config.yaml"
fi
# A configuration preset (config.base.yaml) sits beside the overlay. As in
# fullsend's layered config, an overlay that sets tracker replaces the base
# tracker as a whole object (an explicit empty target policy included);
# otherwise tracker is inherited from the base. A null or bare `tracker:` in
# the overlay counts as unset (it inherits the base), matching that merge.
BASE_CONFIG_FILE="$(dirname "${CONFIG_FILE}")/config.base.yaml"
FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE}}"
TRACKER_PROVIDER="${FULLSEND_TRACKER}"
ALLOW_TARGETS_KEY="tracker.${TRACKER_PROVIDER}.allowed_targets"

# ALLOWED_SCOPES holds GitHub orgs or GitLab groups (a scope admits every
# repository under it, including GitLab subgroups); ALLOWED_REPOS holds
# repositories allowed by exact path (or Jira project keys when FULLSEND_TRACKER=jira).
ALLOWED_SCOPES=""
ALLOWED_REPOS=""
JIRA_ALLOWLIST_STATE="unset"
if [[ -f "${CONFIG_FILE}" || -f "${BASE_CONFIG_FILE}" ]] && ! command -v yq &>/dev/null; then
  echo "::warning::yq not found — cannot read ${ALLOW_TARGETS_KEY} from config; cross-repo issue creation disabled"
  JIRA_ALLOWLIST_STATE="failed"
fi
if command -v yq &>/dev/null; then
  TRACKER_JSON="null"
  OVERLAY_TRACKER_NULL="false"
  for layer_file in "${CONFIG_FILE}" "${BASE_CONFIG_FILE}"; do
    [[ -f "${layer_file}" ]] || continue
    # Fail closed: an unparseable layer disables cross-repo issue creation.
    if ! layer_tracker=$(yq -o=json '.tracker' "${layer_file}" 2>/dev/null); then
      echo "::warning::cannot parse $(basename "${layer_file}") — cross-repo issue creation disabled"
      TRACKER_JSON="null"
      JIRA_ALLOWLIST_STATE="failed"
      break
    fi
    # The old create_issues.allow_targets key is no longer read.
    if yq -e '.create_issues.allow_targets' "${layer_file}" &>/dev/null; then
      echo "::warning::$(basename "${layer_file}") sets create_issues.allow_targets, which is no longer read — move its targets to ${ALLOW_TARGETS_KEY}"
    fi
    if [[ "${TRACKER_JSON}" == "null" ]]; then
      # An overlay that sets tracker to null inherits the base targets; say so
      # when that keeps cross-repo grants the operator may have meant to clear.
      if [[ "${OVERLAY_TRACKER_NULL}" == "true" ]] && jq -e '[.. | arrays | select(length > 0)] | length > 0' <<<"${layer_tracker}" &>/dev/null; then
        echo "::warning::config.yaml sets tracker to null, so cross-repo targets from $(basename "${layer_file}") are inherited — set an empty ${ALLOW_TARGETS_KEY} in config.yaml to revoke them"
      fi
      TRACKER_JSON="${layer_tracker}"
    fi
    if [[ "${layer_file}" == "${CONFIG_FILE}" && "${layer_tracker}" == "null" && "$(yq 'has("tracker")' "${layer_file}" 2>/dev/null)" == "true" ]]; then
      OVERLAY_TRACKER_NULL="true"
    fi
  done
  # Warn when a tracker mapping selects other or several providers, since it
  # then grants no cross-repo targets.
  TRACKER_PROVIDERS=$(jq -r '
    (if type == "object" then . else {} end) as $t
    | [("github", "gitlab", "jira") | select($t[.] != null)] | join(",")
  ' <<<"${TRACKER_JSON}" 2>/dev/null || true)
  if [[ -n "${TRACKER_PROVIDERS}" && "${TRACKER_PROVIDERS}" != "${TRACKER_PROVIDER}" ]]; then
    echo "::warning::tracker mapping selects provider(s) '${TRACKER_PROVIDERS}' but FULLSEND_TRACKER requires only '${TRACKER_PROVIDER}' — no cross-repo targets granted"
    if [[ "${JIRA_ALLOWLIST_STATE}" != "failed" ]]; then
      JIRA_ALLOWLIST_STATE="failed"
    fi
  fi
  # Honor targets only when the tracker selects exactly one provider and it
  # is the forge issues are created on; otherwise nothing is granted.
  ALLOWED_TARGETS_JSON=$(jq -c --arg provider "${TRACKER_PROVIDER}" '
    (if type == "object" then . else {} end) as $t
    | [("github", "gitlab", "jira") | select($t[.] != null)] as $providers
    | if $providers == [$provider] then ($t[$provider].allowed_targets // {}) else {} end
    | if type == "object" then . else {} end
  ' <<<"${TRACKER_JSON}" 2>/dev/null || echo '{}')
  ALLOWED_SCOPES=$(jq -r --arg provider "${TRACKER_PROVIDER}" '
    (if $provider == "github" then .orgs elif $provider == "gitlab" then .groups else null end)
    | if type == "array" then .[] | strings else empty end
  ' <<<"${ALLOWED_TARGETS_JSON}" 2>/dev/null || true)
  ALLOWED_REPOS=$(jq -r --arg provider "${TRACKER_PROVIDER}" '
    (if $provider == "jira" then .projects else .repos end)
    | if type == "array" then .[] | strings else empty end
  ' <<<"${ALLOWED_TARGETS_JSON}" 2>/dev/null || true)
  if [[ "${TRACKER_PROVIDER}" == "jira" && "${JIRA_ALLOWLIST_STATE}" != "failed" ]]; then
    if [[ "${TRACKER_JSON}" != "null" && -n "${TRACKER_JSON}" ]]; then
      projects_status=$(jq -r '
        if type != "object" or (has("jira") | not) or (.jira | type != "object") then
          "unset"
        elif (.jira | has("allowed_targets")) then
          if (.jira.allowed_targets | type == "object") and (.jira.allowed_targets | has("projects")) then
            if (.jira.allowed_targets.projects | type == "array") then
              "configured"
            else
              "failed"
            end
          elif (.jira.allowed_targets == null) then
            "unset"
          elif (.jira.allowed_targets | type == "object") and ((.jira.allowed_targets | has("projects")) | not) then
            "unset"
          else
            "failed"
          end
        else
          "unset"
        end
      ' <<<"${TRACKER_JSON}" 2>/dev/null || echo "failed")
      if [[ "${projects_status}" == "configured" ]]; then
        JIRA_ALLOWLIST_STATE="configured"
      elif [[ "${projects_status}" == "failed" ]]; then
        JIRA_ALLOWLIST_STATE="failed"
      fi
    fi
  fi
fi

# The originating repo is always implicitly allowed.
is_target_allowed() {
  local target_repo="$1"
  local scope

  if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
    if [[ "${target_repo}" == "${ORIGINATING_REPO}" ]]; then
      return 0
    fi
    case "${JIRA_ALLOWLIST_STATE}" in
      failed)
        return 1
        ;;
      configured)
        if [[ -n "${ALLOWED_REPOS}" ]] && echo "${ALLOWED_REPOS}" | grep -qFx "${target_repo}"; then
          return 0
        fi
        return 1
        ;;
      unset)
        return 0
        ;;
    esac
  fi

  # Source repo is always allowed.
  if [[ "${target_repo}" == "${ORIGINATING_REPO}" ]]; then
    return 0
  fi

  # Check org/group allowlist (a group also covers its subgroups' projects).
  while IFS= read -r scope; do
    if [[ -n "${scope}" && "${target_repo}" == "${scope}/"* ]]; then
      return 0
    fi
  done <<<"${ALLOWED_SCOPES}"

  # Check repo allowlist.
  if [[ -n "${ALLOWED_REPOS}" ]] && echo "${ALLOWED_REPOS}" | grep -qFx "${target_repo}"; then
    return 0
  fi

  return 1
}

# File an issue for each proposal.
PROPOSAL_COUNT=$(jq '.proposals | length' "${RESULT_FILE}")
echo "Found ${PROPOSAL_COUNT} proposal(s)"

# Validate all proposals before filing any to avoid partial state.
# Guard on PROPOSAL_COUNT > 0: `seq 0 $((PROPOSAL_COUNT - 1))` with
# PROPOSAL_COUNT=0 becomes `seq 0 -1`, which some seq implementations treat
# as a descending range (0, -1) rather than empty, causing an out-of-bounds
# proposals[0] access when there are no proposals.
if [[ "${PROPOSAL_COUNT}" -gt 0 ]]; then
  for i in $(seq 0 $((PROPOSAL_COUNT - 1))); do
    TR=$(jq -r ".proposals[$i].target_repo" "${RESULT_FILE}")
    if [[ ! "${TR}" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+$ ]]; then
      echo "ERROR: proposal[$i].target_repo is not a valid repo path: $(_gha_sanitize "${TR}")" >&2
      exit 1
    fi
    TI=$(jq -r ".proposals[$i].title // empty" "${RESULT_FILE}")
    if [[ -z "${TI}" ]]; then
      echo "ERROR: proposal[$i].title is missing or empty" >&2
      exit 1
    fi
    jq -e ".proposals[$i] | .what_happened and .what_could_go_better and .proposed_change and .validation_criteria" "${RESULT_FILE}" >/dev/null 2>&1 || {
      echo "ERROR: proposal[$i] is missing required fields" >&2
      exit 1
    }
  done
fi
echo "All ${PROPOSAL_COUNT} proposal(s) validated"

# Jira: fail before any create call if the configured project/issue type
# needs required fields retro does not set.
if [[ "${FULLSEND_TRACKER}" == "jira" && "${PROPOSAL_COUNT}" -gt 0 && "${RETRO_MODE}" != "summary_only" ]]; then
  if ! tracker_validate_create; then
    echo "ERROR: Jira project validation failed — no issues created" >&2
    exit 1
  fi
fi

ISSUE_LINKS=""
EVIDENCE_NOTES=""
FILTERED_COUNT=0
SKIPPED_TARGETS=""
RECEIPT_SKIPPED=""
FAILED_PROPOSALS=""
SUMMARY_ONLY_PROPOSALS=""
if [[ "${PROPOSAL_COUNT}" -gt 0 ]]; then
  for i in $(seq 0 $((PROPOSAL_COUNT - 1))); do
    TARGET_REPO=$(jq -r ".proposals[$i].target_repo" "${RESULT_FILE}")
    TITLE=$(jq -r ".proposals[$i].title" "${RESULT_FILE}")
    SAFE_TITLE=$(_gha_sanitize "${TITLE}")

    # Deterministic gate: reject "Evidence for" proposals.
    # The retro-analysis skill instructs the agent not to file these, but the
    # agent ignores the instruction frequently enough that a post-script gate
    # is needed. See fullsend-ai/fullsend#3881.
    TITLE_LOWER=$(printf '%s' "${TITLE}" | tr '[:upper:]' '[:lower:]')
    if [[ "${TITLE_LOWER}" =~ ^evidence[[:space:]]+(for|of)[[:space:]]+([\#!]) ]] || \
       [[ "${TITLE_LOWER}" =~ ^evidence: ]] || \
       [[ "${TITLE_LOWER}" =~ ^additional[[:space:]]+evidence ]]; then
      echo "::warning::proposal[$i] rejected — title matches evidence-for pattern: ${SAFE_TITLE}. Folding into summary."
      EVIDENCE_NOTES="${EVIDENCE_NOTES}
- **${TITLE}** (${TARGET_REPO}): $(jq -r ".proposals[$i].what_happened | split(\"\\n\")[0]" "${RESULT_FILE}")"
      FILTERED_COUNT=$((FILTERED_COUNT + 1))
      continue
    fi

    if [[ "${RETRO_MODE}" == "summary_only" ]]; then
      echo "Mode is summary_only — skipping issue creation for proposal[$i] (${SAFE_TITLE})"
      SUMMARY_ONLY_PROPOSALS="${SUMMARY_ONLY_PROPOSALS}
- **${TITLE}** (\`${TARGET_REPO}\`): $(jq -r ".proposals[$i].what_happened | split(\"\\n\")[0]" "${RESULT_FILE}")"
      continue
    fi

    # Allowlist gate: reject proposals targeting repos not in allowed_targets.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      if ! is_target_allowed "${RETRO_JIRA_PROJECT}"; then
        echo "::warning::Skipping issue creation in Jira project '${RETRO_JIRA_PROJECT}' — not in ${ALLOW_TARGETS_KEY}"
        SKIPPED_TARGETS="${SKIPPED_TARGETS}
- **${TITLE}** (\`${RETRO_JIRA_PROJECT}\`)"
        continue
      fi
    else
      if ! is_target_allowed "${TARGET_REPO}"; then
        echo "::warning::Skipping issue creation in '${TARGET_REPO}' — not in ${ALLOW_TARGETS_KEY}"
        SKIPPED_TARGETS="${SKIPPED_TARGETS}
- **${TITLE}** (\`${TARGET_REPO}\`)"
        continue
      fi
    fi

    # Dedup-receipt gate: skip proposals without a well-formed duplicate-search
    # receipt. This is the enforcement for #1730 — related_issues is optional in
    # the schema (a missing/weak receipt must skip only its own proposal, not
    # fail whole-result validation and drop valid siblings and the summary), so
    # the gate validates the full receipt shape here, on both the validated and
    # fallback (no FULLSEND_VALIDATED_ITERATION_DIR) paths. The shape check is
    # exhaustive because the body builder below iterates searched and found and
    # concatenates note: a non-array searched or a non-string note would abort
    # BODY=$(...) under `set -e` mid-loop, after earlier proposals were filed.
    # Requirements: searched is an array of >= 2 distinct, non-blank strings;
    # found (if present) is an array; note (if present) is a string.
    if ! jq -e "
      .proposals[$i].related_issues as \$r |
      (\$r | type) == \"object\"
      and (\$r.searched | type) == \"array\"
      and (\$r.searched | length) >= 2
      and (\$r.searched | map(select(type == \"string\" and (gsub(\"^\\\\s+|\\\\s+\$\"; \"\") | length > 0))) | length) == (\$r.searched | length)
      and (\$r.searched | unique | length) == (\$r.searched | length)
      and ((\$r | has(\"found\") | not) or (\$r.found | type) == \"array\")
      and ((\$r | has(\"note\") | not) or (\$r.note | type) == \"string\")
    " "${RESULT_FILE}" >/dev/null 2>&1; then
      echo "::warning::proposal[$i] not filed — missing or malformed dedup receipt (related_issues.searched must be at least 2 distinct non-empty phrases). Folding into summary."
      RECEIPT_SKIPPED="${RECEIPT_SKIPPED}
- **${TITLE}** (${TARGET_REPO}): $(jq -r ".proposals[$i].what_happened | split(\"\\n\")[0]" "${RESULT_FILE}")"
      continue
    fi

    # Build the issue body from the four sections, plus the dedup receipt.
    BODY=$(jq -r --arg url "${ORIGINATING_URL}" "
      .proposals[$i] |
      \"## What happened\n\n\" + .what_happened +
      \"\n\n## What could go better\n\n\" + .what_could_go_better +
      \"\n\n## Proposed change\n\n\" + .proposed_change +
      \"\n\n## Validation criteria\n\n\" + .validation_criteria +
      \"\n\n## Related issues checked\n\nSearched: \" +
      (.related_issues.searched | join(\"; \")) +
      (if (.related_issues.found // []) | length > 0 then
        \"\nConsidered: \" + (.related_issues.found | map(if type == \"number\" then \"#\" + tostring else tostring end) | join(\", \")) +
        (if .related_issues.note then \"\n\" + .related_issues.note else \"\" end)
      else
        \"\nNo overlapping issues found.\"
      end) +
      \"\n\n---\n_Generated by retro agent from \" + \$url + \"_\"
    " "${RESULT_FILE}")

    # TODO(#833): Remove this warning once per-repo customization is stable.
    # Depends on: #195, #179, #419, PR #792, PR #799.
    if [[ "${TARGET_REPO}" == */.fullsend ]]; then
      echo "::warning::proposal[$i] targets a .fullsend repo (${TARGET_REPO}). Filing in .fullsend repos is discouraged until per-repo customization patterns are stable. Consider filing in the source repo or fullsend-ai/fullsend upstream instead."
    fi

    # Jira rerun protection: skip if an issue with the same summary exists.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      if ! EXISTING_URL=$(tracker_find_existing_issue "${TITLE}"); then
        echo "::warning::Jira duplicate check failed for proposal[$i] (${SAFE_TITLE}) — refusing to create issue"
        FAILED_PROPOSALS="${FAILED_PROPOSALS}
- **${TITLE}** (\`${RETRO_JIRA_PROJECT}\`)"
        continue
      fi
      if [[ -n "${EXISTING_URL}" ]]; then
        echo "Skipping proposal[$i] (${SAFE_TITLE}) — already exists in Jira: ${EXISTING_URL}"
        ISSUE_LINKS="${ISSUE_LINKS}- [${TITLE}](${EXISTING_URL}) (in \`${RETRO_JIRA_PROJECT}\`)
"
        continue
      fi
    fi

    # Ensure the label exists in the target repo before applying it.
    # Follows the same pattern as post-review.sh for ready-for-merge.
    # --force / idempotent creation makes this safe to repeat.
    forge_create_label "${TARGET_REPO}" "ready-for-triage" \
      "Triggers triage agent dispatch" "0E8A16"

    SAFE_TITLE=$(_gha_sanitize "${TITLE}")
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      echo "Filing issue in Jira ${RETRO_JIRA_PROJECT}: ${SAFE_TITLE}"
    else
      echo "Filing issue in ${TARGET_REPO}: ${SAFE_TITLE}"
    fi

    # A failed creation is non-fatal: record it, keep filing the remaining
    # proposals, and report it in the summary comment.
    CREATE_RC=0
    ISSUE_URL=$(forge_create_issue "${TARGET_REPO}" "${TITLE}" "${BODY}" "ready-for-triage") || CREATE_RC=$?
    if [[ ${CREATE_RC} -ne 0 && ${CREATE_RC} -ne 2 ]]; then
      SAFE_OUTPUT=$(_gha_sanitize "${ISSUE_URL}")
      if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
        echo "::warning::Failed to create Jira issue in ${RETRO_JIRA_PROJECT} for proposal[$i] (${SAFE_TITLE}): ${SAFE_OUTPUT}"
        FAILED_PROPOSALS="${FAILED_PROPOSALS}
- **${TITLE}** (\`${RETRO_JIRA_PROJECT}\`)"
      else
        echo "::warning::Failed to create issue in ${TARGET_REPO} for proposal[$i] (${SAFE_TITLE}): ${SAFE_OUTPUT}"
        FAILED_PROPOSALS="${FAILED_PROPOSALS}
- **${TITLE}** (\`${TARGET_REPO}\`)"
      fi
      continue
    fi

    if [[ ${CREATE_RC} -eq 2 ]]; then
      SAFE_URL=$(_gha_sanitize "${ISSUE_URL}")
      echo "::warning::Issue created but failed to apply label in Jira for proposal[$i] (${SAFE_TITLE}): ${SAFE_URL}"
    fi

    echo "Created: ${ISSUE_URL}"
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      ISSUE_LINKS="${ISSUE_LINKS}- [${TITLE}](${ISSUE_URL}) (in \`${RETRO_JIRA_PROJECT}\`)
"
    else
      ISSUE_LINKS="${ISSUE_LINKS}- [${TITLE}](${ISSUE_URL}) (in \`${TARGET_REPO}\`)
"
    fi
  done
fi

# Post summary comment on the originating PR/issue.
SUMMARY=$(jq -r '.summary // empty' "${RESULT_FILE}")
if [[ -z "${SUMMARY}" ]]; then
  echo "ERROR: .summary is missing or empty in agent result" >&2
  exit 1
fi

if [[ ${FILTERED_COUNT} -gt 0 ]]; then
  echo "${FILTERED_COUNT} proposal(s) filtered (evidence-for pattern)"
fi

COMMENT="${SUMMARY}"
if [[ -n "${ISSUE_LINKS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals filed\n\n%s' "${COMMENT}" "${ISSUE_LINKS}")
fi
if [[ -n "${SUMMARY_ONLY_PROPOSALS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals (issue creation disabled)\n%s' "${COMMENT}" "${SUMMARY_ONLY_PROPOSALS}")
fi
if [[ -n "${FAILED_PROPOSALS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals not filed (issue creation failed)\n\nFile manually; see the post-retro logs for the error:\n%s' "${COMMENT}" "${FAILED_PROPOSALS}")
fi
if [[ -n "${EVIDENCE_NOTES}" ]]; then
  COMMENT=$(printf '%s\n\n### Evidence notes (not filed as issues)\n%s' "${COMMENT}" "${EVIDENCE_NOTES}")
fi
if [[ -n "${SKIPPED_TARGETS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals skipped (target repo not allowed)\n\nFile manually or update `%s` in config.yaml:\n%s' "${COMMENT}" "${ALLOW_TARGETS_KEY}" "${SKIPPED_TARGETS}")
fi
if [[ -n "${RECEIPT_SKIPPED}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals skipped (no dedup receipt)\n\nNot filed because they did not record a valid duplicate search (`related_issues`). Re-run retro, or search for duplicates and file manually:\n%s' "${COMMENT}" "${RECEIPT_SKIPPED}")
fi

# Truncate to forge-specific comment limit.
MAX_COMMENT_LEN=$(forge_get_comment_max_len)
if [[ ${#COMMENT} -gt ${MAX_COMMENT_LEN} ]]; then
  TRUNCATION_SUFFIX=$'\n\n...(truncated)'
  COMMENT="${COMMENT:0:$((MAX_COMMENT_LEN - ${#TRUNCATION_SUFFIX}))}"${TRUNCATION_SUFFIX}
fi

if [[ "${RETRO_MODE}" == "issues_only" ]]; then
  echo "Mode is issues_only — skipping summary comment posting"
  echo "Post-retro complete."
  exit 0
fi

echo "Posting summary comment on ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}"
# Note: we handle 401/403 inline rather than relying on github-api-csma.sh
# because the intent is different. CSMA retries rate-limited requests; here
# we want graceful degradation when the token permanently lacks permission
# to comment on a specific repo. Retrying a 403 permission error is futile.
COMMENT_OUTPUT=""
COMMENT_EXIT=0
COMMENT_OUTPUT=$(forge_post_comment "${ORIGINATING_REPO}" "${ORIGINATING_NUMBER}" "${COMMENT}") || COMMENT_EXIT=$?

if [[ ${COMMENT_EXIT} -ne 0 ]]; then
  # Treat 401/403 as non-fatal — the token lacks permission to comment on
  # this repo, but the core deliverables (analysis + proposal issues) are
  # already complete. See #2305.
  if echo "${COMMENT_OUTPUT}" | grep -qE "HTTP (401|403)|error: (401|403)"; then
    # Sanitize before interpolating into GHA workflow command to prevent
    # injecting ::set-output or ::save-state directives via crafted responses.
    SAFE_OUTPUT=$(_gha_sanitize "${COMMENT_OUTPUT}")
    echo "::warning::Could not post summary comment to ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}: insufficient permissions (${SAFE_OUTPUT}). Skipping."
  else
    # Sanitize before echoing to prevent GHA workflow command injection.
    SAFE_OUTPUT=$(_gha_sanitize "${COMMENT_OUTPUT}")
    echo "ERROR: failed to post summary comment on ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}: ${SAFE_OUTPUT}"
    exit 1
  fi
fi

echo "Post-retro complete."
