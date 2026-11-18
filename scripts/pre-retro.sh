#!/usr/bin/env bash
# GENERATED from pre-retro.src.sh — DO NOT EDIT. Run: make script-build
# pre-retro.sh — Validate inputs for the retro agent.
#
# Runs on the host via the harness pre_script mechanism. Validates the
# originating URL (PR or issue) and logs the trigger context.
#
# Required env vars:
#   ORIGINATING_URL — HTML URL of the PR or issue that triggered retro
#   FULLSEND_FORGE  — "github" or "gitlab"
#
# Optional env vars:
#   RETRO_COMMENT   — The /retro comment text (empty for automatic triggers)
#   FULLSEND_TRACKER — "github", "gitlab", or "jira" (defaults to FULLSEND_FORGE)
#   FULLSEND_DIR    — .fullsend directory (required when FULLSEND_TRACKER=jira)

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

# shellcheck source=github-host.lib.sh
# BEGIN bundled: lib/github-host.lib.sh
# shellcheck shell=bash
# github-host.lib.sh — Shared GitHub host handling for GitHub ops.
#
# Derives the GitHub origin the run executes against from GITHUB_SERVER_URL,
# a GitHub Actions default variable (https://github.com on github.com, the
# instance URL on GitHub Enterprise Server). Defaults to https://github.com
# when unset. Issue/PR URL validation, URL parsing and generated links use
# this origin instead of a hard-coded github.com.
#
# Sourced by the github-*-ops.lib.sh files and inlined by the bundler.

[[ -n "${GITHUB_HOST_SH_LOADED:-}" ]] && return 0
GITHUB_HOST_SH_LOADED=1

# Prints the GitHub origin (https://host[:port]) without a trailing slash.
# Fails closed when GITHUB_SERVER_URL is not an HTTPS origin.
_github_server_url() {
  local origin="${GITHUB_SERVER_URL:-https://github.com}"
  origin="${origin%/}"
  if [[ ! "${origin}" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
    echo "ERROR: GITHUB_SERVER_URL is not an HTTPS origin (https://host[:port]): $(printf '%s' "${origin}" | tr -d '\n\r')" >&2
    return 1
  fi
  printf '%s\n' "${origin}"
}

# Prints the remainder of a URL after "<origin>/" when the URL is on the
# GitHub origin; fails (printing nothing) when it is on another host.
_github_url_path() {
  local url="$1" base
  base="$(_github_server_url)/" || return 1
  [[ "${url}" == "${base}"* ]] || return 1
  printf '%s\n' "${url#"${base}"}"
}
# END bundled: lib/github-host.lib.sh

# --- URL handling ---

_forge_validate_originating_url() {
  local path
  if ! path=$(_github_url_path "${ORIGINATING_URL}") \
    || [[ ! "${path}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/(issues|pull)/[0-9]+$ ]]; then
    echo "ERROR: ORIGINATING_URL does not match expected pattern: $(_gha_sanitize "${ORIGINATING_URL}")" >&2
    return 1
  fi
}
forge_validate_originating_url() {
  _forge_validate_originating_url
}

_forge_parse_originating_url() {
  # shellcheck disable=SC2034 # ORIGINATING_REPO consumed by callers after function returns
  ORIGINATING_REPO=$(_github_url_path "${ORIGINATING_URL}" | sed -E 's#/(issues|pull)/.*##')
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
# bundled into each script that sources it. Three credential modes
# (fullsend#9007, agents#1926):
#
#   token + email      — bot user: Basic auth with email:token
#   token only         — service account: Bearer auth with the token
#   client credentials — service account OAuth 2.0 client credentials
#                        (FULLSEND_JIRA_CLIENT_ID and
#                        FULLSEND_JIRA_CLIENT_SECRET): REST calls use a
#                        Bearer access token minted on the runner, and the
#                        fullsend CLI gets the client credentials and mints
#                        for itself
#
# An email that is empty or only whitespace counts as absent. A harness
# that maps an unset FULLSEND_JIRA_EMAIL to JIRA_USER_EMAIL yields an empty
# string, and that must select Bearer, never an empty-user Basic header.
#
# Every helper takes the token and email as arguments, so callers that
# withhold the credentials from their environment can pass saved copies.
# jira_auth_select chooses the mode once; until it is called, the helpers
# use the token and email they are given (the token modes).
#
# The client secret is kept in shell variables only. It never reaches a
# command line, a file, the output, or an xtrace line: jira_auth_select
# takes the names of the client ID and secret variables and reads them
# with xtrace off, jq builds the token request body from its environment
# and sends it to curl on stdin, and a failed request reports its HTTP
# status, never the response body.

[[ -n "${JIRA_AUTH_SH_LOADED:-}" ]] && return 0
JIRA_AUTH_SH_LOADED=1

# Selected mode: "token", "client", or "none". Empty until jira_auth_select.
JIRA_AUTH_MODE=""
_JIRA_AUTH_CLIENT_ID=""
_JIRA_AUTH_CLIENT_SECRET=""
_JIRA_AUTH_ACCESS_TOKEN=""
_JIRA_AUTH_EXPIRES_AT=0

# Print the argument with surrounding whitespace removed.
_jira_auth_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

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

# Select the credential mode and set JIRA_AUTH_MODE:
#   token  — a token is set (the email decides Basic or Bearer per call)
#   client — the client ID and secret are both set and no token is
#   none   — nothing is set
# The client ID and secret are passed as variable names, never values, so
# a traced call line shows only the names; they are read with xtrace off.
# Fails, naming the variables but never their values, when a token and
# client credentials are both set, only one client variable is, or a name
# is not a shell identifier. Values are trimmed, so one that is only
# whitespace counts as unset.
#
# Usage: jira_auth_select <token> <client-id-var> <client-secret-var>
jira_auth_select() {
  local _jas_xtrace=0 _jas_rc=0
  if [[ $- == *x* ]]; then
    _jas_xtrace=1
    set +x
  fi
  _jira_auth_select_now "$@" || _jas_rc=$?
  if [[ "${_jas_xtrace}" -eq 1 ]]; then
    set -x
  fi
  return "${_jas_rc}"
}

# Locals use a _jas_ prefix, and such names are refused, so the indirect
# reads see the caller's variables, not these.
_jira_auth_select_now() {
  local _jas_name
  for _jas_name in "$2" "$3"; do
    if [[ ! "${_jas_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || "${_jas_name}" == _jas_* ]]; then
      echo "ERROR: jira_auth_select needs the names of the client ID and secret variables" >&2
      return 1
    fi
  done
  local _jas_token _jas_id _jas_secret
  _jas_token="$(_jira_auth_trim "$1")"
  _jas_id="$(_jira_auth_trim "${!2:-}")"
  _jas_secret="$(_jira_auth_trim "${!3:-}")"
  if [[ -n "${_jas_token}" && ( -n "${_jas_id}" || -n "${_jas_secret}" ) ]]; then
    echo "ERROR: set either FULLSEND_JIRA_TOKEN (JIRA_TOKEN) or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET, not both" >&2
    return 1
  fi
  if [[ -n "${_jas_id}" && -z "${_jas_secret}" ]] || [[ -z "${_jas_id}" && -n "${_jas_secret}" ]]; then
    echo "ERROR: FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET must be set together" >&2
    return 1
  fi
  _JIRA_AUTH_ACCESS_TOKEN=""
  _JIRA_AUTH_EXPIRES_AT=0
  if [[ -n "${_jas_token}" ]]; then
    JIRA_AUTH_MODE="token"
  elif [[ -n "${_jas_id}" ]]; then
    JIRA_AUTH_MODE="client"
    _JIRA_AUTH_CLIENT_ID="${_jas_id}"
    _JIRA_AUTH_CLIENT_SECRET="${_jas_secret}"
  else
    JIRA_AUTH_MODE="none"
  fi
}

# In client-credentials mode, fail unless JIRA_API_URL is set. A minted
# access token works only through the Atlassian API gateway
# (https://api.atlassian.com/ex/jira/<cloudId>); the site URL in
# JIRA_BASE_URL rejects it, so there is no fallback.
#
# Usage: jira_auth_require_api_url
jira_auth_require_api_url() {
  if [[ "${JIRA_AUTH_MODE}" == "client" && -z "${JIRA_API_URL:-}" ]]; then
    echo "ERROR: JIRA_API_URL (the Atlassian API gateway URL) must be set when FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET are used; JIRA_BASE_URL does not accept their access tokens" >&2
    return 1
  fi
}

# In client-credentials mode, make sure a usable access token is held:
# mint one when there is none or it expires within 5 minutes. A no-op in
# the other modes. The token is kept in a shell variable only and masked
# before anything else is printed. Mint once in the script's own shell,
# with stdout not redirected, so the mask line reaches the log and later
# calls, including those in command substitutions, reuse the token.
#
# Usage: jira_auth_mint
jira_auth_mint() {
  [[ "${JIRA_AUTH_MODE}" == "client" ]] || return 0
  local now
  now="$(date +%s)"
  if [[ -n "${_JIRA_AUTH_ACCESS_TOKEN}" ]] && (( now < _JIRA_AUTH_EXPIRES_AT - 300 )); then
    return 0
  fi
  local xtrace=0 rc=0
  if [[ $- == *x* ]]; then
    xtrace=1
    set +x
  fi
  _jira_auth_mint_now "${now}" || rc=$?
  if [[ "${xtrace}" -eq 1 ]]; then
    set -x
  fi
  return "${rc}"
}

# Request an access token the way fullsend does
# (internal/forge/jira/oauth.go). Called by jira_auth_mint with xtrace off.
# jq builds the body from the trimmed ID and secret in its environment and
# curl reads it on stdin; curl -q ignores curl config files.
_jira_auth_mint_now() {
  local now="$1"
  local raw rc=0
  raw="$(_JIRA_AUTH_ID="${_JIRA_AUTH_CLIENT_ID}" \
    _JIRA_AUTH_SECRET="${_JIRA_AUTH_CLIENT_SECRET}" \
    jq -cn '{grant_type: "client_credentials", client_id: env._JIRA_AUTH_ID, client_secret: env._JIRA_AUTH_SECRET}' \
    | curl -q --proto =https --silent --connect-timeout 10 --max-time 30 \
      --header "Content-Type: application/json" \
      --data @- \
      --write-out '\n%{http_code}' \
      "https://auth.atlassian.com/oauth/token" 2>/dev/null)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: Jira OAuth token request failed (curl exit ${rc})" >&2
    return 1
  fi
  local http_code="${raw##*$'\n'}"
  local body="${raw%$'\n'*}"
  [[ "${http_code}" =~ ^[0-9]{3}$ ]] || http_code="unknown"
  if [[ "${http_code}" != 2?? ]]; then
    echo "ERROR: Jira OAuth token request failed (HTTP ${http_code})" >&2
    return 1
  fi
  local token expires_in
  token="$(printf '%s' "${body}" | jq -r '.access_token // empty' 2>/dev/null)" || token=""
  expires_in="$(printf '%s' "${body}" | jq -r '.expires_in // empty' 2>/dev/null)" || expires_in=""
  # Atlassian access tokens are JWTs. Anything outside this charset could
  # break or inject into the ::add-mask:: line, so it is refused unprinted.
  if [[ ! "${token}" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "ERROR: Jira OAuth token response has no usable access_token" >&2
    return 1
  fi
  # In the script's own shell the mask goes to stdout. In a subshell, such
  # as a command substitution, stdout may be captured, so it goes to the
  # main shell's current stdout through /proc when that is a pipe or a
  # terminal (the runner log), else to stderr. A file or /dev/null there
  # means the caller redirected stdout around the call.
  local main_out="/proc/$$/fd/1"
  if (( BASH_SUBSHELL == 0 )); then
    printf '::add-mask::%s\n' "${token}"
  elif [[ -w "${main_out}" ]] && [[ -p "${main_out}" || -c "${main_out}" ]] \
    && ! [[ "${main_out}" -ef /dev/null ]]; then
    printf '::add-mask::%s\n' "${token}" >> "${main_out}"
  else
    printf '::add-mask::%s\n' "${token}" >&2
  fi
  [[ "${expires_in}" =~ ^[0-9]+$ ]] || expires_in=3600
  _JIRA_AUTH_ACCESS_TOKEN="${token}"
  _JIRA_AUTH_EXPIRES_AT=$((now + expires_in))
}

# Run curl with the Authorization for the selected mode, followed by the
# caller's arguments. In client-credentials mode the token and email
# arguments are ignored and the minted access token is sent as Bearer.
# Otherwise fails without calling curl when the token is empty.
#
# Usage: jira_auth_curl <token> <email> [curl args...]
jira_auth_curl() {
  local token="$1"
  local email
  email="$(jira_auth_email "$2")"
  shift 2
  if [[ "${JIRA_AUTH_MODE}" == "client" ]]; then
    jira_auth_mint || return 1
    curl --oauth2-bearer "${_JIRA_AUTH_ACCESS_TOKEN}" "$@"
    return
  fi
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
# the CLI cannot pick Basic auth. In client-credentials mode the CLI gets
# FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET, with
# FULLSEND_JIRA_TOKEN and FULLSEND_JIRA_EMAIL removed, and mints for
# itself, with xtrace off. The values go through the environment, never
# the command line.
#
# Usage: jira_auth_fullsend <fullsend-bin> <token> <email> [cli args...]
jira_auth_fullsend() {
  local bin="$1"
  local token="$2"
  local email
  email="$(jira_auth_email "$3")"
  shift 3
  if [[ "${JIRA_AUTH_MODE}" == "client" ]]; then
    local xtrace=0 rc=0
    if [[ $- == *x* ]]; then
      xtrace=1
      set +x
    fi
    (
      unset FULLSEND_JIRA_TOKEN FULLSEND_JIRA_EMAIL
      FULLSEND_JIRA_CLIENT_ID="${_JIRA_AUTH_CLIENT_ID}" \
        FULLSEND_JIRA_CLIENT_SECRET="${_JIRA_AUTH_CLIENT_SECRET}" "${bin}" "$@"
    ) || rc=$?
    if [[ "${xtrace}" -eq 1 ]]; then
      set -x
    fi
    return "${rc}"
  fi
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
RETRO_JIRA_LABELS="${RETRO_JIRA_LABELS-ready-for-triage}"
if [[ -z "${RETRO_JIRA_LABELS}" ]]; then
  echo "INFO: RETRO_JIRA_LABELS is empty — Jira issues will be created without labels" >&2
fi
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
    --arg allowlist "${RETRO_JIRA_LABELS}" '
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
    if [[ -n "${labels}" && -n "${RETRO_JIRA_LABELS}" ]]; then
      echo "WARNING: no requested Jira labels are allowed by RETRO_JIRA_LABELS; issue will be created without labels" >&2
    fi
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
  # Drop Jira text-search stop words so they cannot exclude an exact summary.
  # With no usable terms, search the project and compare summaries client-side.
  terms=$(printf '%s' "${title}" | jq -Rs '[scan("[\\p{L}\\p{N}]+") | ascii_downcase] | unique | map(select(length > 2 and (.[0:1] | IN("a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is", "it", "no", "not", "of", "on", "or", "such", "that", "the", "their", "then", "there", "these", "they", "this", "to", "was", "will", "with") | not))) | sort_by(-length) | .[0:3]') || return 1
  if [[ "$(printf '%s' "${terms}" | jq 'length')" -eq 0 ]]; then
    terms='[]'
  fi
  raw_file=$(mktemp)
  jql=$(printf '%s' "${terms}" | jq -r --arg proj "$(_retro_jql_quote "${RETRO_JIRA_PROJECT}")" '
    ["project = " + $proj] + map("summary ~ \"" + (gsub("\\\\"; "\\\\\\\\") | gsub("\""; "\\\"")) + "\"") | join(" AND ")
  ')
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
  # Jira issue keys are <PROJECT>-<NUMBER>; fullsend's --number expects the numeric suffix.
  local num="${number##*-}"
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${repo}" --number "${num}" \
    --marker "<!-- fullsend:retro-agent -->" --result - 2>&1
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
    echo "32000"
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
forge_mask_token

if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
  if [[ "${RETRO_MODE:-all}" != "summary_only" || "${JIRA_ORIGINATING:-false}" == "true" ]]; then
    if [[ -z "${FULLSEND_DIR:-}" ]]; then
      echo "ERROR: FULLSEND_DIR must be set when FULLSEND_TRACKER=jira (the fullsend CLI reads tracker.jira from its config.yaml)" >&2
      exit 1
    fi
  fi
fi

echo "::notice::Retro target: $(_gha_sanitize "${ORIGINATING_URL}")"

if [[ -n "${RETRO_COMMENT:-}" ]]; then
  echo "Retro triggered on-demand with comment."
else
  echo "Retro triggered automatically (PR close)."
fi

echo "Pre-retro validation complete."
