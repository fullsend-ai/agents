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
#   FULLSEND_TRACKER — "jira", or the same value as FULLSEND_FORGE
#                      (defaults to FULLSEND_FORGE)
#   FULLSEND_DIR    — .fullsend directory (required when FULLSEND_TRACKER=jira)
#
# When FULLSEND_TRACKER=jira, scripts/lib/jira-retro-ops.lib.sh (sourced
# through retro-ops.lib.sh) also enforces JIRA_BASE_URL, RETRO_JIRA_PROJECT
# and a Jira credential, and reads tracker.jira from FULLSEND_DIR's config.
# RETRO_MODE=summary_only relaxes those requirements: no issue is filed.
# A Jira-originated run additionally requires RETRO_JIRA_CONTEXT_FILE: the
# path this script writes the issue context to is the host_files src the
# harness mounts into the sandbox.

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

_gha_mask() {
  local value="$1"
  value="${value//%/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  printf '::add-mask::%s\n' "${value}"
}

# RETRO_MODE is validated here, before the tracker library is sourced, because
# jira-retro-ops.lib.sh branches on it at source time: a typo such as
# `summary-only` would otherwise take the full path and fail later with a
# misleading missing-credential error, and pre-retro, which also sources this
# file, would never reject it at all.
RETRO_MODE="${RETRO_MODE:-all}"
case "${RETRO_MODE}" in
  all|summary_only|issues_only) ;;
  *)
    echo "ERROR: RETRO_MODE must be 'all', 'summary_only', or 'issues_only' (got: $(_gha_sanitize "${RETRO_MODE}"))" >&2
    exit 1
    ;;
esac

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
    _gha_mask "${GH_TOKEN}"
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
    _gha_mask "${GITLAB_TOKEN}"
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
#   JIRA_TOKEN             — Jira API token. Or, instead of it:
#   FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET — OAuth client
#                            credentials, mutually exclusive with JIRA_TOKEN
#   FULLSEND_DIR           — .fullsend directory whose config.yaml holds
#                            tracker.jira, for fullsend issues shell-outs
#   RETRO_JIRA_PROJECT     — Jira project key for proposal issues (e.g. "PROJ")
#
# Optional env vars:
#   JIRA_USER_EMAIL        — bot-user email. When set, requests use Basic
#                            auth with email and token; when unset or empty,
#                            Bearer auth with a service-account token.
#   RETRO_JIRA_ISSUE_TYPE  — issue type name for created issues (default: "Task")
#   RETRO_JIRA_LABELS      — comma-separated allowlist of labels that retro may
#                            apply to Jira issues (default: "ready-for-triage").
#                            Labels are added by an issue update, which Jira
#                            checks against the issue edit screen, so an issue
#                            type whose edit screen has no Labels field gets no
#                            labels and a warning.
#   RETRO_JIRA_MAX_PAGES   — maximum pages fetched per paginated Jira read (default: 50)
#   RETRO_MODE             — "all" (default), "summary_only", or "issues_only"
#   RETRO_JIRA_CONTEXT_FILE — absolute host path the pre-script writes the
#                            originating Jira issue context to. Required for a
#                            Jira-originated run: harness/retro.yaml mounts
#                            exactly this path into the sandbox (host_files
#                            src), and a ${VAR}-expanded src is the only form
#                            fullsend accepts when the harness is loaded from a
#                            URL or used as a `base:`.
#   RETRO_JIRA_CONTEXT_MAX_BYTES — byte cap for the context file; the oldest
#                            comments are dropped first (default: 262144)
#   RETRO_JIRA_CONTEXT_MAX_PAGES — comment pages fetched for the context file;
#                            the cap drops the newest comments (default: 10)
#   RETRO_JIRA_CONTEXT_COMMENT_CHARS — per-comment character cap in the
#                            context file (default: 4000)
#   RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS — description character cap in the
#                            context file (default: 20000)
#
# REST routing mirrors fullsend's Jira Scoped client
# (internal/forge/jira/scoped.go), as jira-prioritize-ops.lib.sh does:
# tracker.jira.api_url in FULLSEND_DIR's config is the gateway base (default
# https://api.atlassian.com), the cloud ID is discovered from the site at
# tracker.jira.base_url (<site>/_edge/tenant_info), and every REST call goes
# to <api_url>/ex/jira/<cloudId>/rest/api/3/... . A JIRA_API_URL environment
# variable is not read: the gateway comes only from tracker.jira in the
# config, as it does for the `fullsend issues` CLI. Configuration is read
# from FULLSEND_DIR, the same directory the CLI reads.

[[ -n "${JIRA_RETRO_OPS_SH_LOADED:-}" ]] && return 0
JIRA_RETRO_OPS_SH_LOADED=1

RETRO_JIRA_PROJECT="${RETRO_JIRA_PROJECT:-}"
RETRO_MODE="${RETRO_MODE:-all}"
if [[ "${RETRO_MODE}" != "summary_only" ]]; then
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

# Emit a GitHub Actions masking command for a secret. Defined here rather
# than in a caller's library so every bundle that sources Jira auth can mask
# a minted token, whatever the agent. Percent signs, CR and LF are escaped
# because an unescaped line break would end the workflow command.
_jira_auth_gha_mask() {
  local value="$1"
  value="${value//%/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  printf '::add-mask::%s\n' "${value}"
}

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
  # break or inject into the workflow command, so it is refused unprinted.
  if [[ ! "${token}" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "ERROR: Jira OAuth token response has no usable access_token" >&2
    return 1
  fi
  # ::add-mask:: is a GitHub Actions workflow command. On any other runner
  # the line is ordinary log output and would print the token, so the mask
  # is emitted only when GITHUB_ACTIONS is "true".
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    # In the script's own shell the mask goes to stdout. In a subshell, such
    # as a command substitution, stdout may be captured, so it goes to the
    # main shell's current stdout through /proc when that is a pipe or a
    # terminal (the runner log), else to stderr. A file or /dev/null there
    # means the caller redirected stdout around the call.
    local main_out="/proc/$$/fd/1"
    if (( BASH_SUBSHELL == 0 )); then
      _jira_auth_gha_mask "${token}"
    elif [[ -w "${main_out}" ]] && [[ -p "${main_out}" || -c "${main_out}" ]] \
      && ! [[ "${main_out}" -ef /dev/null ]]; then
      _jira_auth_gha_mask "${token}" >> "${main_out}"
    else
      _jira_auth_gha_mask "${token}" >&2
    fi
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

# Credentials are expanded into curl and CLI arguments below. Turn xtrace
# off around those expansions so `bash -x` / `set -x` never writes the token
# to the trace, then restore the caller's setting.
_RETRO_JIRA_XTRACE=0
_retro_jira_xtrace_off() {
  _RETRO_JIRA_XTRACE=0
  if [[ $- == *x* ]]; then
    _RETRO_JIRA_XTRACE=1
    set +x
  fi
}
_retro_jira_xtrace_restore() {
  if [[ "${_RETRO_JIRA_XTRACE}" -eq 1 ]]; then
    set -x
  fi
}

_retro_jira_select_rc=0
_retro_jira_xtrace_off
jira_auth_select "${JIRA_TOKEN:-}" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET || _retro_jira_select_rc=$?
_retro_jira_xtrace_restore
if [[ "${_retro_jira_select_rc}" -ne 0 ]]; then
  exit 1
fi

if [[ "${RETRO_MODE}" != "summary_only" && "${JIRA_AUTH_MODE}" == "none" ]]; then
  echo "ERROR: JIRA_TOKEN must be set, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
  exit 1
fi
# Client-credentials access tokens are accepted by the Atlassian API
# gateway, which tracker.jira.api_url points at, so no separate gateway URL
# is required. The resolved endpoint is validated per call.

if [[ -n "${JIRA_BASE_URL:-}" ]]; then
  while [[ "${JIRA_BASE_URL}" == */ ]]; do
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"
  done
  if [[ ! "${JIRA_BASE_URL}" =~ ^https://[a-zA-Z0-9-]+\.atlassian\.net$ ]]; then
    echo "ERROR: JIRA_BASE_URL must be a Jira Cloud URL (https://<site>.atlassian.net)" >&2
    exit 1
  fi
fi

if [[ "${RETRO_MODE}" != "summary_only" ]]; then
  [[ -n "${FULLSEND_DIR:-}" ]] || {
    echo "ERROR: FULLSEND_DIR must be set when FULLSEND_TRACKER=jira" >&2
    exit 1
  }
fi

# Client-credentials tokens are not minted at source time: pre-retro mints
# and caches the REST root via _retro_jira_init only when JIRA_ORIGINATING=true
# to fetch the originating issue context, while forge-originated runs make no
# Jira calls in pre-retro. post-retro calls _retro_jira_init once in the main
# shell before the proposal loop. Minting there (rather than per call) keeps
# the token and REST root in the main process cache, avoiding token exchanges
# and tenant_info lookups inside subshell command substitutions.

if [[ -n "${RETRO_JIRA_PROJECT}" && ! "${RETRO_JIRA_PROJECT}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
  echo "ERROR: RETRO_JIRA_PROJECT must be a Jira project key (e.g. PROJ)" >&2
  exit 1
fi

RETRO_JIRA_ISSUE_TYPE="${RETRO_JIRA_ISSUE_TYPE:-Task}"
RETRO_JIRA_LABELS="${RETRO_JIRA_LABELS-ready-for-triage}"
RETRO_JIRA_LABELS_CONFIGURED="${RETRO_JIRA_LABELS}"
if [[ -z "${RETRO_JIRA_LABELS}" ]]; then
  echo "INFO: RETRO_JIRA_LABELS is empty — Jira issues will be created without labels" >&2
fi
RETRO_JIRA_MAX_PAGES="${RETRO_JIRA_MAX_PAGES:-50}"
# Used as an arithmetic bound, so anything outside a plain positive integer is
# refused: 0 yields a silent "truncated" duplicate search and a failing
# createmeta, and bash arithmetic would evaluate the contents of the value.
if [[ ! "${RETRO_JIRA_MAX_PAGES}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_MAX_PAGES must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_MAX_PAGES}"))" >&2
  exit 1
fi

# --- Configuration and REST routing ---

# Print the effective value of tracker.jira.<key> from the configuration in
# FULLSEND_DIR. The overlay (config.yaml) is composed over config.base.yaml
# with fullsend's whole-object tracker merge: an overlay that sets tracker
# replaces the base tracker as a whole object; a missing, null or bare
# tracker inherits the base. Prints nothing when no layer sets the key.
# Fails closed (non-zero) when a layer exists but cannot be read, so a yq
# parse error is never mistaken for "no config" and calls are not routed to
# the default gateway by accident.
_retro_jira_config_value() {
  local key="$1" cfg tracker value=""
  [[ -n "${FULLSEND_DIR:-}" ]] || return 0
  [[ -f "${FULLSEND_DIR}/config.yaml" || -f "${FULLSEND_DIR}/config.base.yaml" ]] || return 0
  if ! command -v yq &>/dev/null; then
    echo "ERROR: a Jira config file exists under FULLSEND_DIR but yq is not installed — cannot read tracker.jira.${key}" >&2
    return 1
  fi
  for cfg in "${FULLSEND_DIR}/config.yaml" "${FULLSEND_DIR}/config.base.yaml"; do
    [[ -f "${cfg}" ]] || continue
    tracker=$(yq -o=json '.tracker' "${cfg}" 2>/dev/null) || {
      echo "ERROR: failed to parse $(basename "${cfg}") — cannot read tracker.jira.${key}" >&2
      return 1
    }
    # An unset, null or bare tracker inherits the next layer.
    [[ "${tracker}" == "null" || -z "${tracker}" ]] && continue
    value=$(yq -r ".tracker.jira.${key} // \"\"" "${cfg}" 2>/dev/null) || {
      echo "ERROR: failed to parse tracker.jira.${key} from ${cfg}" >&2
      return 1
    }
    break
  done
  printf '%s' "${value}"
}

# Print the argument without trailing slashes.
_retro_jira_trim_url() {
  local url="$1"
  while [[ -n "${url}" && "${url}" == */ ]]; do
    url="${url%/}"
  done
  printf '%s' "${url}"
}

# Discover the site's cloud ID from <site>/_edge/tenant_info. The lookup is
# unauthenticated and does not follow redirects. The value must be a UUID
# before it is placed in a URL path.
_retro_jira_cloud_id() {
  local site="$1" resp id
  resp=$(curl -q --proto '=https' --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    "${site}/_edge/tenant_info") || {
    echo "ERROR: failed to discover the Jira cloud ID from ${site}/_edge/tenant_info" >&2
    return 1
  }
  id=$(printf '%s' "${resp}" | jq -r '.cloudId // empty' 2>/dev/null) || id=""
  if [[ ! "${id}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "ERROR: Jira cloud ID discovery from ${site} returned no valid cloudId" >&2
    return 1
  fi
  printf '%s' "${id}"
}

# Print the REST root for Jira Cloud REST API v3:
#   <tracker.jira.api_url>/ex/jira/<cloudId>/rest/api/3
# tracker.jira.api_url is the gateway base (default https://api.atlassian.com)
# and tracker.jira.base_url, when set, must name the JIRA_BASE_URL tenant so
# a config cannot route reads to a different site than the CLI writes to.
# Fails closed when the site or cloud ID cannot be resolved.
_retro_jira_rest_root() {
  local gateway site cfg_base cloud
  [[ -n "${JIRA_BASE_URL:-}" ]] || {
    echo "ERROR: JIRA_BASE_URL is not set" >&2
    return 1
  }
  gateway=$(_retro_jira_config_value api_url) || return 1
  gateway=$(_retro_jira_trim_url "${gateway:-https://api.atlassian.com}")
  if [[ ! "${gateway}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    echo "ERROR: tracker.jira.api_url is not a plain https URL: $(_gha_sanitize "${gateway}")" >&2
    return 1
  fi
  site="${JIRA_BASE_URL}"
  cfg_base=$(_retro_jira_config_value base_url) || return 1
  cfg_base=$(_retro_jira_trim_url "${cfg_base}")
  if [[ -n "${cfg_base}" && "${cfg_base}" != "${site}" ]]; then
    echo "ERROR: tracker.jira.base_url ('$(_gha_sanitize "${cfg_base}")') does not match JIRA_BASE_URL ('$(_gha_sanitize "${site}")') — refusing to route Jira calls to a different tenant" >&2
    return 1
  fi
  cloud=$(_retro_jira_cloud_id "${site}") || return 1
  printf '%s/ex/jira/%s/rest/api/3' "${gateway}" "${cloud}"
}

# Resolve the REST root once per run, in the calling shell. Every REST call
# below runs inside a command substitution, so a root resolved there is lost
# with the subshell and repeats 2-4 yq reads and an unauthenticated
# tenant_info request per call. Called from post-retro after configuration is
# parsed and before the proposal loop, as jira-prioritize-ops.lib.sh does
# with its cloud-ID cache.
_RETRO_JIRA_REST_ROOT=""
_retro_jira_init() {
  [[ "${RETRO_MODE}" == "summary_only" && "${JIRA_ORIGINATING:-false}" != "true" ]] && return 0
  # Mint in the calling shell so the token cache survives the subshells.
  jira_auth_mint || return 1
  local root=""
  # A resolution failure is not fatal here: _retro_jira_api re-resolves it and
  # reports the error for the proposal it affects, as it did before caching.
  if root=$(_retro_jira_rest_root); then
    _RETRO_JIRA_REST_ROOT="${root}"
  fi
  return 0
}

# --- Jira REST calls ---

_retro_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local rest_root="${_RETRO_JIRA_REST_ROOT:-}" rc=0
  if [[ -z "${rest_root}" ]]; then
    rest_root=$(_retro_jira_rest_root) || return 1
  fi
  _retro_jira_xtrace_off
  jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    "${rest_root}${endpoint}" \
    "$@" || rc=$?
  _retro_jira_xtrace_restore
  return "${rc}"
}

_retro_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file raw http_code body rest_root="${_RETRO_JIRA_REST_ROOT:-}" rc=0
  if [[ -z "${rest_root}" ]]; then
    rest_root=$(_retro_jira_rest_root) || return 1
  fi
  err_file=$(mktemp)
  _retro_jira_xtrace_off
  raw=$(jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${rest_root}${endpoint}" \
    "$@" 2>"${err_file}") || rc=$?
  _retro_jira_xtrace_restore
  if [[ "${rc}" -ne 0 ]]; then
    echo "Jira API error: curl failed — $(_gha_sanitize "$(cat "${err_file}")")" >&2
    rm -f "${err_file}"
    return 1
  fi
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

# --- Originating-issue context for the sandbox ---
#
# A Jira-originated retro runs in a sandbox with no route to Atlassian and no
# Jira credential, so pre-retro fetches the originating issue and its comments
# here, on the host, and the harness mounts the result into the sandbox
# (harness/retro.yaml host_files -> /sandbox/workspace/jira-origin.json, read
# by the agent as RETRO_JIRA_CONTEXT). Nothing in the sandbox talks to Jira.
#
# The path is the runner's, not a default: harness/retro.yaml declares it as
# the host_files src, so the path written here and the path mounted there must
# be the same value. pre-retro refuses a Jira-originated run without it.
RETRO_JIRA_CONTEXT_FILE="${RETRO_JIRA_CONTEXT_FILE:-}"
RETRO_JIRA_CONTEXT_MAX_BYTES="${RETRO_JIRA_CONTEXT_MAX_BYTES:-262144}"
RETRO_JIRA_CONTEXT_MAX_PAGES="${RETRO_JIRA_CONTEXT_MAX_PAGES:-10}"
RETRO_JIRA_CONTEXT_COMMENT_CHARS="${RETRO_JIRA_CONTEXT_COMMENT_CHARS:-4000}"
RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS="${RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS:-20000}"
# Used as arithmetic or jq bounds, so refuse anything but a positive integer,
# as RETRO_JIRA_MAX_PAGES does.
if [[ ! "${RETRO_JIRA_CONTEXT_MAX_BYTES}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_CONTEXT_MAX_BYTES must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_CONTEXT_MAX_BYTES}"))" >&2
  exit 1
fi
if [[ ! "${RETRO_JIRA_CONTEXT_MAX_PAGES}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_CONTEXT_MAX_PAGES must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_CONTEXT_MAX_PAGES}"))" >&2
  exit 1
fi
if [[ ! "${RETRO_JIRA_CONTEXT_COMMENT_CHARS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_CONTEXT_COMMENT_CHARS must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_CONTEXT_COMMENT_CHARS}"))" >&2
  exit 1
fi
if [[ ! "${RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS}"))" >&2
  exit 1
fi

# Fetch every comment on an issue, oldest first, into a JSON array file.
# Pagination is bounded by RETRO_JIRA_CONTEXT_MAX_PAGES; a read stopped by that
# cap sets _RETRO_JIRA_COMMENTS_TRUNCATED, which the context builder copies into
# the file so the agent knows the list is incomplete. orderBy is explicit
# because the cap drops newest comments when the order is ascending, which is
# the order the byte-size trim and the docs assume.
_RETRO_JIRA_COMMENTS_TRUNCATED="false"
_retro_jira_fetch_comments() {
  local key="$1" out="$2" start=0 page resp count total
  _RETRO_JIRA_COMMENTS_TRUNCATED="false"
  printf '[]' > "${out}"
  for ((page = 1; page <= RETRO_JIRA_CONTEXT_MAX_PAGES; page++)); do
    resp=$(_retro_jira_api GET "/issue/${key}/comment?maxResults=100&startAt=${start}&orderBy=created") || return 1
    count=$(printf '%s' "${resp}" | jq -r '(.comments // []) | length') || return 1
    if ! printf '%s' "${resp}" | jq -c '(.comments // [])' \
      | jq -sc '.[0] + .[1]' "${out}" - > "${out}.tmp"; then
      echo "ERROR: Jira comment fetch returned a malformed response" >&2
      rm -f "${out}.tmp"
      return 1
    fi
    # Called through `if !`, so errexit is off here: an unchecked mv failure
    # would leave the previous page in place and silently lose this one.
    if ! mv "${out}.tmp" "${out}"; then
      rm -f "${out}.tmp"
      echo "ERROR: failed to accumulate the Jira comment page" >&2
      return 1
    fi
    total=$(printf '%s' "${resp}" | jq -r '.total // empty')
    start=$((start + count))
    if [[ "${count}" -eq 0 ]] || [[ -n "${total}" && "${start}" -ge "${total}" ]]; then
      return 0
    fi
  done
  echo "WARNING: Jira comments stopped after ${RETRO_JIRA_CONTEXT_MAX_PAGES} pages; the sandbox context is truncated" >&2
  _RETRO_JIRA_COMMENTS_TRUNCATED="true"
  return 0
}

# Build the sandbox context file for the originating Jira issue. Prints the
# path written. Fails closed: the agent must not run a retrospective it
# cannot read.
_retro_jira_write_context() {
  local key="$1" file="${RETRO_JIRA_CONTEXT_FILE}"
  local raw_issue comments_file issue_file tmp
  if [[ ! "${key}" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]]; then
    echo "ERROR: cannot read a Jira issue key from '$(_gha_sanitize "${key}")'" >&2
    return 1
  fi
  if [[ -z "${file}" ]]; then
    echo "ERROR: RETRO_JIRA_CONTEXT_FILE is not set — harness/retro.yaml mounts that path into the sandbox as RETRO_JIRA_CONTEXT" >&2
    return 1
  fi
  # The harness mounts this path as a host path, so a relative value would
  # write a file under this script's working directory and pass the -s check
  # below while the sandbox mount expands to something else, running the agent
  # without its context. Docs and the overlay example require an absolute path.
  if [[ "${file}" != /* ]]; then
    echo "ERROR: RETRO_JIRA_CONTEXT_FILE must be an absolute path (got: $(_gha_sanitize "${file}")) — harness/retro.yaml mounts it as a host path" >&2
    return 1
  fi
  if [[ -z "${JIRA_BASE_URL:-}" ]]; then
    echo "ERROR: JIRA_BASE_URL is not set" >&2
    return 1
  fi
  raw_issue=$(_retro_jira_api GET "/issue/${key}?fields=summary,description,status,issuetype,labels,created,updated,reporter,assignee,project,issuelinks,parent") || {
    echo "ERROR: failed to read Jira issue ${key}" >&2
    return 1
  }
  comments_file=$(mktemp)
  if ! _retro_jira_fetch_comments "${key}" "${comments_file}"; then
    rm -f "${comments_file}"
    echo "ERROR: failed to read comments on Jira issue ${key}" >&2
    return 1
  fi
  # The issue document goes in through a file, not argv: it holds the ADF
  # description, which is far larger than its text, and Linux caps a single
  # argument at 128 KiB (MAX_ARG_STRLEN), so --argjson fails with E2BIG on a
  # big issue. macOS has no such limit, so a local run would not show it.
  issue_file=$(mktemp)
  if ! printf '%s' "${raw_issue}" > "${issue_file}"; then
    rm -f "${comments_file}" "${issue_file}"
    echo "ERROR: failed to stage the Jira issue response" >&2
    return 1
  fi
  tmp=$(mktemp)
  if ! jq -n \
    --arg key "${key}" \
    --arg url "${JIRA_BASE_URL}/browse/${key}" \
    --slurpfile issue "${issue_file}" \
    --slurpfile comments "${comments_file}" \
    --argjson comments_truncated "${_RETRO_JIRA_COMMENTS_TRUNCATED}" \
    --argjson comment_chars "${RETRO_JIRA_CONTEXT_COMMENT_CHARS}" \
    --argjson description_chars "${RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS}" \
    --arg generated_by "retro pre-script (host-side fetch; the sandbox has no Jira access)" '
    # Jira stores rich text as ADF. Keep unknown node types as their text
    # children so a schema addition degrades instead of disappearing.
    def adf:
      if type == "string" then .
      elif type == "array" then map(adf) | join("")
      elif type == "object" then
        (if .type == "text" then (.text // "")
         elif .type == "hardBreak" then "\n"
         elif .type == "paragraph" then ((.content // [] | adf) + "\n")
         elif .type == "heading" then
           (("#" * ((.attrs.level // 1) | tonumber)) + " " + ((.content // [] | adf)) + "\n")
         elif .type == "codeBlock" then ("```\n" + ((.content // [] | adf)) + "```\n")
         elif .type == "listItem" then ("- " + ((.content // [] | adf)))
         elif .type == "mention" then ("@" + (.attrs.text // .attrs.displayName // "user"))
         elif .type == "inlineCard" then ((.attrs.url // "") + "\n")
         elif .type == "rule" then "---\n"
         else (.content // [] | adf) end)
      else "" end;
    def text_or_null:
      if . == null then "" else (adf | gsub("\\n{3,}"; "\n\n") | ltrimstr("\n") | rtrimstr("\n")) end;
    def clip(n): if length > n then .[0:n] + "\n…(truncated)" else . end;
    ($issue[0].fields // {}) as $f |
    {
      source: "jira",
      generated_by: $generated_by,
      issue: {
        key: $key,
        url: $url,
        summary: ($f.summary // ""),
        project: ($f.project.key // ""),
        issue_type: ($f.issuetype.name // ""),
        status: ($f.status.name // ""),
        labels: (($f.labels // []) | map(select(type == "string"))),
        created: ($f.created // ""),
        updated: ($f.updated // ""),
        reporter: ($f.reporter.displayName // ""),
        assignee: ($f.assignee.displayName // ""),
        parent: ($f.parent.key // ""),
        links: (($f.issuelinks // [])
          | map({type: (.type.name // ""), key: (((.outwardIssue // .inwardIssue) // {}).key // "")})
          | map(select(.key != ""))),
        description: (($f.description | text_or_null) | clip($description_chars)),
        description_truncated: ((($f.description | text_or_null) | length) > $description_chars)
      },
      comments: (($comments[0] // [])
        | map({
            id: (.id // ""),
            author: (.author.displayName // ""),
            created: (.created // ""),
            body: ((.body | text_or_null) | clip($comment_chars))
          })),
      comments_truncated: $comments_truncated
    }' > "${tmp}"; then
    rm -f "${comments_file}" "${issue_file}" "${tmp}"
    echo "ERROR: failed to assemble the Jira context file" >&2
    return 1
  fi
  rm -f "${comments_file}" "${issue_file}"
  # Keep the file under the size cap by dropping the oldest comments first:
  # the newest discussion is what a retrospective needs most.
  while [[ "$(wc -c < "${tmp}" | tr -d '[:space:]')" -gt "${RETRO_JIRA_CONTEXT_MAX_BYTES}" ]] \
    && [[ "$(jq '.comments | length' "${tmp}")" -gt 0 ]]; do
    if ! jq '(.comments | length) as $n
      | .comments = .comments[(if $n > 4 then ($n / 4 | floor) else 1 end):]
      | .comments_truncated = true' "${tmp}" > "${tmp}.cut"; then
      rm -f "${tmp}" "${tmp}.cut"
      echo "ERROR: failed to trim the Jira context file" >&2
      return 1
    fi
    # The while condition re-reads "${tmp}": an unchecked failure to replace it
    # would leave the file over the cap and loop forever.
    if ! mv "${tmp}.cut" "${tmp}"; then
      rm -f "${tmp}" "${tmp}.cut"
      echo "ERROR: failed to rewrite the trimmed Jira context file" >&2
      return 1
    fi
  done
  chmod 600 "${tmp}"
  # The caller reads this function's return status through `if !`, which turns
  # errexit off for the whole body, so each step needs an explicit check: a
  # silent mkdir/mv failure would report success and leave the run without the
  # context file it needs.
  mkdir -p "$(dirname "${file}")" || {
    rm -f "${tmp}"
    echo "ERROR: cannot create the directory for RETRO_JIRA_CONTEXT_FILE: $(dirname "${file}")" >&2
    return 1
  }
  mv "${tmp}" "${file}" || {
    rm -f "${tmp}"
    echo "ERROR: cannot move the Jira context file into place: ${file}" >&2
    return 1
  }
  printf '%s' "${file}"
}

# Jira Cloud rejects a summary longer than 255 characters or one that contains a
# line break, and fullsend's `issues create --tracker jira` sends the title as
# in.Summary unchanged. The retro schema allows a 256-character title and does
# not forbid newlines (schemas/retro-result.schema.json), so a schema-valid
# title can fail to file. Normalize it once in post-retro, before the in-run
# title set, the duplicate search and the create, so dedupe compares the same
# value Jira stores. jq slices by code point, so a multi-byte character is never
# split.
RETRO_JIRA_SUMMARY_MAX_CHARS=255
_retro_jira_normalize_summary() {
  printf '%s' "$1" | jq -Rrs --argjson max "${RETRO_JIRA_SUMMARY_MAX_CHARS}" \
    'gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "") | .[0:$max]'
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
    --arg allowlist "${RETRO_JIRA_LABELS_CONFIGURED}" '
    def parse_list:
      if (type == "array") then .
      elif (type == "string") then [split(",")[] | gsub("^\\s+|\\s+$"; "")]
      else [] end;
    def parse_raw:
      ($raw | try fromjson catch $raw) | parse_list;
    def parse_allowlist:
      if $allowlist == "" then [] else $allowlist | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(test("^[A-Za-z0-9._-]{1,64}$"))) end;
    (parse_allowlist) as $allowed |
    [parse_raw[]?
      | select(type == "string")
      | gsub("^\\s+|\\s+$"; "")
      | select(test("^[A-Za-z0-9._-]{1,64}$"))
      | select(. as $item | $allowed | index($item))
    ] | reduce .[] as $item ([]; if index($item) then . else . + [$item] end) | .[0:10]
  '
}

# Jira validates a label update against the issue's edit screen, not the create
# screen createmeta reports: an issue type can offer Labels at creation and
# still refuse the update, or omit it at creation and accept the update. Label
# support is therefore decided from `GET /issue/{key}/editmeta`, and the answer
# is cached for the run because tracker_apply_labels runs in the calling shell.
# Only a successful read is cached: a failed probe leaves the state unknown and
# is retried for the next issue, since the label update still runs either way.
_RETRO_JIRA_LABELS_EDITABLE="unknown"

# Fail (non-zero) when the issue's edit screen has no Labels field, so no
# update is sent that Jira would reject.
_retro_jira_labels_editable() {
  local key="$1" editmeta
  case "${_RETRO_JIRA_LABELS_EDITABLE}" in
    yes) return 0 ;;
    no) return 1 ;;
  esac
  if ! editmeta=$(_retro_jira_api GET "/issue/${key}/editmeta"); then
    # Unknown rather than blocked: the update below reports its own failure.
    echo "WARNING: cannot read Jira edit metadata for ${key}; attempting the label update anyway" >&2
    return 0
  fi
  if printf '%s' "${editmeta}" | jq -e '((.fields // {}) | type == "object") and ((.fields // {}) | has("labels"))' >/dev/null 2>&1; then
    _RETRO_JIRA_LABELS_EDITABLE="yes"
    return 0
  fi
  _RETRO_JIRA_LABELS_EDITABLE="no"
  echo "WARNING: issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' in Jira project ${RETRO_JIRA_PROJECT} has no Labels field on its edit screen; labels will be omitted" >&2
  return 1
}

_retro_jira_add_labels() {
  local key="$1" labels="$2"
  local labels_json ops
  if [[ "${RETRO_JIRA_LABELS_CONFIGURED}" == "" ]]; then
    return 0
  fi
  labels_json=$(_retro_jira_filter_labels "${labels}")
  if [[ "$(printf '%s' "${labels_json}" | jq 'length')" -eq 0 ]]; then
    if [[ -n "${labels}" && -n "${RETRO_JIRA_LABELS}" ]]; then
      echo "WARNING: no requested Jira labels are allowed by RETRO_JIRA_LABELS; issue will be created without labels" >&2
    fi
    return 0
  fi
  if ! _retro_jira_labels_editable "${key}"; then
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
  local help_text
  # The create call below passes both options, so the installed CLI must
  # support both. Cobra prints "Usage:" and the command path on separate
  # lines, so match the command path itself rather than a contiguous
  # "Usage: <cmd>" string. Any help output that does not establish the
  # create command and both options fails preflight here, instead of every
  # proposal failing later with an unknown-flag error.
  if ! help_text=$(fullsend issues create --help 2>&1) \
    || [[ "${help_text}" != *"fullsend issues create"* ]] \
    || [[ "${help_text}" != *"--fullsend-dir"* ]] \
    || [[ "${help_text}" != *"--tracker"* ]]; then
    echo "ERROR: installed fullsend does not support 'issues create --tracker jira --fullsend-dir'; upgrade to a version with config-backed Jira issue creation (fullsend#7083 / fullsend#9078)" >&2
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
  # reporter is exempt because Jira fills it with the calling account when the
  # field is omitted. createmeta still reports it as required with no default
  # for an account that holds Modify Reporter permission, so without this
  # exemption every proposal would be refused on a project retro can file in.
  missing=$(printf '%s' "${meta}" | jq -r '
    [.[]
      | select(.required == true and (.hasDefaultValue // false) == false)
      | select((.fieldId // .key) as $f | ["project","issuetype","summary","description","reporter"] | index($f) | not)
      | (.fieldId // .key)] | join(", ")')
  if [[ -n "${missing}" ]]; then
    echo "ERROR: Jira project ${RETRO_JIRA_PROJECT} requires fields retro does not set: $(_gha_sanitize "${missing}")" >&2
    return 1
  fi
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "description")' >/dev/null; then
    echo "ERROR: issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' in Jira project ${RETRO_JIRA_PROJECT} has no Description field on its create screen" >&2
    return 1
  fi
  # Labels are not checked here: they are written by an issue update, which
  # Jira validates against the edit screen, not this create screen. See
  # tracker_apply_labels.
}

tracker_find_existing_issue() {
  local title="$1" raw_file jql terms match rc=0
  # Search terms are whole whitespace-separated words of letters and digits;
  # a dotted or hyphenated token such as `post-retro.sh` is not split, since
  # Jira may index it as one token and a fragment would miss the exact
  # summary. Stop words are dropped so they cannot exclude an exact summary.
  # With no usable terms, search the project and compare summaries
  # client-side.
  terms=$(printf '%s' "${title}" | jq -Rs '[splits("[[:space:]]+") | select(test("^[\\p{L}\\p{N}]+$")) | ascii_downcase] | unique | map(select(length > 2 and (. as $word | (["a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is", "it", "no", "not", "of", "on", "or", "such", "that", "the", "their", "then", "there", "these", "they", "this", "to", "was", "will", "with"] | index($word) | not)))) | sort_by(-length) | .[0:3]') || return 1
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

# Titles filed, or matched as already filed, earlier in this run, with their
# issue URLs. The duplicate search below is the only rerun protection and it
# reads /search/jql, whose index lags behind writes: a second proposal with the
# same summary, or a retry moments after a create, would not see the issue the
# earlier iteration just filed. Checking this set first closes that gap. It
# lives in the calling shell (post-retro's proposal loop), which is also where
# the create runs.
_RETRO_JIRA_RUN_TITLES='[]'
_retro_jira_title_seen() {
  jq -e --arg t "$1" 'map(select(.title == $t)) | length > 0' <<<"${_RETRO_JIRA_RUN_TITLES}" >/dev/null 2>&1
}
_retro_jira_title_url() {
  jq -r --arg t "$1" '[.[] | select(.title == $t)][0].url // empty' <<<"${_RETRO_JIRA_RUN_TITLES}" 2>/dev/null
}
_retro_jira_record_title() {
  _RETRO_JIRA_RUN_TITLES=$(jq -c --arg t "$1" --arg u "${2:-}" '. + [{title: $t, url: $u}]' <<<"${_RETRO_JIRA_RUN_TITLES}")
}

forge_create_issue() {
  # The fourth argument is the label list, which post-retro applies with
  # tracker_apply_labels after the create (labels are an edit-screen field).
  # shellcheck disable=SC2034
  local _repo="$1" title="$2" body="$3" labels="${4:-ready-for-triage}"
  if [[ -z "${body}" || "${body}" == "-" ]]; then
    body=$(cat)
  fi
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: forge_create_issue: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  local response key url rc=0
  _retro_jira_xtrace_off
  response=$(printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues create \
    --tracker jira \
    --fullsend-dir "${FULLSEND_DIR}" \
    --project "${RETRO_JIRA_PROJECT}" \
    --type "${RETRO_JIRA_ISSUE_TYPE}" \
    --title "${title}" \
    --body -) || rc=$?
  _retro_jira_xtrace_restore
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: forge_create_issue: fullsend issues create failed in project ${RETRO_JIRA_PROJECT}" >&2
    return 1
  fi
  key=$(printf '%s' "${response}" | jq -r '.key // empty' 2>/dev/null)
  url=$(printf '%s' "${response}" | jq -r '.url // empty' 2>/dev/null)
  if [[ -z "${key}" ]] || [[ ! "${key}" =~ ^${RETRO_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: forge_create_issue: fullsend issues create returned no valid issue key" >&2
    return 1
  fi
  if [[ -n "${url}" ]]; then
    echo "${url}"
  else
    echo "${JIRA_BASE_URL}/browse/${key}"
  fi
}

# Apply RETRO_JIRA_LABELS to a created issue. post-retro calls this in its own
# shell, after a successful create, so the edit-screen probe in
# _retro_jira_labels_editable is cached for the proposals that follow:
# forge_create_issue runs in a command substitution, whose variable state does
# not survive.
#
# Usage: tracker_apply_labels <issue-url> <labels>
tracker_apply_labels() {
  local url="$1" labels="$2" key
  key="${url##*/}"
  if [[ ! "${key}" =~ ^${RETRO_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: tracker_apply_labels: cannot read a ${RETRO_JIRA_PROJECT} issue key from '$(_gha_sanitize "${url}")'" >&2
    return 1
  fi
  _retro_jira_add_labels "${key}" "${labels}"
}

forge_create_label() {
  # Jira labels are ad-hoc strings and do not require pre-creation.
  return 0
}

# --- Originating URL handling and comments ---

forge_validate_originating_url() {
  if [[ "${ORIGINATING_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    local host
    host=$(echo "${ORIGINATING_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
    case "${host}" in
      *.atlassian.net)
        if [[ -z "${JIRA_BASE_URL:-}" ]]; then
          echo "ERROR: JIRA_BASE_URL must be set for a Jira-originated run" >&2
          return 1
        fi
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

# `fullsend issues post-comment` updates a marked comment in place. Older
# CLIs keep the replaced text as a collapsed "Previous run" block unless
# --keep-history=false is passed, which would stack a copy of the previous
# summary on every rerun. fullsend-ai/fullsend#9399, still open, proposes
# deprecating the flag and posting every result as a new comment; once that
# merges, passing the flag prints a warning and has no effect, and each rerun
# adds another summary comment instead of replacing the previous one. The
# flag is therefore passed only when the CLI's flag table lists it without
# "deprecated", which covers a released CLI either way.
# Sets _RETRO_JIRA_KEEP_HISTORY_ARGS in the caller's shell.
_RETRO_JIRA_KEEP_HISTORY_ARGS=()
_retro_jira_keep_history_args() {
  _RETRO_JIRA_KEEP_HISTORY_ARGS=()
  local help_text line has_flag=0 deprecated=0
  if ! help_text=$(fullsend issues post-comment --help 2>&1); then
    # A broken CLI fails the post itself, with its own error.
    return 0
  fi
  help_text=$(printf '%s\n' "${help_text}" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r line; do
    [[ "${line}" =~ ^[[:space:]]+--keep-history([=[:space:]]|$) ]] || continue
    has_flag=1
    if [[ "${line}" == *deprecated* ]]; then
      deprecated=1
    fi
  done <<< "${help_text}"
  if [[ "${has_flag}" -eq 1 && "${deprecated}" -eq 0 ]]; then
    _RETRO_JIRA_KEEP_HISTORY_ARGS=(--keep-history=false)
  fi
}

_retro_jira_post_comment() {
  local repo="$1" number="$2" body="$3"
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  if [[ "${JIRA_AUTH_MODE}" == "none" ]]; then
    echo "ERROR: Jira credentials must be set to post comments to Jira" >&2
    return 1
  fi
  # Jira issue keys are <PROJECT>-<NUMBER>; fullsend's --number expects the numeric suffix.
  local num="${number##*-}"
  local rc=0
  _retro_jira_keep_history_args
  _retro_jira_xtrace_off
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${repo}" --number "${num}" \
    --marker "<!-- fullsend:retro-agent -->" \
    ${_RETRO_JIRA_KEEP_HISTORY_ARGS[@]+"${_RETRO_JIRA_KEEP_HISTORY_ARGS[@]}"} \
    --result - 2>&1 || rc=$?
  _retro_jira_xtrace_restore
  return "${rc}"
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
    if [[ "${JIRA_AUTH_MODE}" == "none" ]]; then
      echo "ERROR: JIRA_TOKEN must be set, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
      return 1
    fi
  fi
  if [[ "${jira_origin}" == "true" ]]; then
    return 0
  fi
  # issues_only posts no forge comment, so a forge token is not required for
  # a Jira-backed run that only files issues.
  if [[ "${RETRO_MODE}" == "issues_only" ]]; then
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
  # The test below and the mask itself both expand the token, so keep them
  # out of any xtrace.
  _retro_jira_xtrace_off
  if [[ -n "${GITHUB_ACTIONS:-}" && -n "${JIRA_TOKEN:-}" ]]; then
    _gha_mask "${JIRA_TOKEN}"
  fi
  _retro_jira_xtrace_restore
}

forge_get_comment_max_len() {
  # The Jira comment limit is not exposed here: post-retro applies it with
  # _retro_jira_fit_comment (RETRO_JIRA_COMMENT_MAX_BYTES) for a Jira-originated
  # run and only reaches this function for a forge comment.
  if declare -f _forge_get_comment_max_len >/dev/null 2>&1; then
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

# A runner that reuses its host keeps RETRO_JIRA_CONTEXT_FILE between runs, and
# harness/retro.yaml uploads it on every retro run, so a stale file would put an
# earlier Jira issue's text into an unrelated run's sandbox. Drop it here, for
# forge-originated runs too; a Jira-originated run writes a fresh one below.
if [[ -n "${RETRO_JIRA_CONTEXT_FILE:-}" ]]; then
  rm -f "${RETRO_JIRA_CONTEXT_FILE}" || true
fi

if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
  if [[ "${RETRO_MODE:-all}" != "summary_only" || "${JIRA_ORIGINATING:-false}" == "true" ]]; then
    if [[ -z "${FULLSEND_DIR:-}" ]]; then
      echo "ERROR: FULLSEND_DIR must be set when FULLSEND_TRACKER=jira (the fullsend CLI reads tracker.jira from its config.yaml)" >&2
      exit 1
    fi
  fi
fi

echo "::notice::Retro target: $(_gha_sanitize "${ORIGINATING_URL}")"

# A Jira-originated run analyzes a work item the sandbox cannot reach: it has
# no Atlassian route and no Jira credential. Fetch the issue and its comments
# here, on the host, into the context file the harness mounts into the
# sandbox (harness/retro.yaml host_files, exposed as RETRO_JIRA_CONTEXT).
# Fail closed: a retrospective that cannot read its subject would file
# proposals it cannot substantiate.
if [[ "${JIRA_ORIGINATING:-false}" == "true" ]]; then
  # The harness declares this path as its host_files src, and fullsend expands
  # ${VAR} in that src from the runner environment, so an unset value would
  # mount nothing and the agent would run blind. Fail here instead.
  if [[ -z "${RETRO_JIRA_CONTEXT_FILE:-}" ]]; then
    echo "ERROR: RETRO_JIRA_CONTEXT_FILE must be set for a Jira-originated retro — harness/retro.yaml mounts that path into the sandbox as RETRO_JIRA_CONTEXT" >&2
    exit 1
  fi
  if [[ "${JIRA_AUTH_MODE:-none}" == "none" ]]; then
    echo "ERROR: a Jira-originated retro needs JIRA_TOKEN, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
    exit 1
  fi
  _retro_jira_xtrace_off
  _retro_jira_init_rc=0
  _retro_jira_init || _retro_jira_init_rc=$?
  _retro_jira_xtrace_restore
  if [[ "${_retro_jira_init_rc}" -ne 0 ]]; then
    echo "ERROR: failed to initialize Jira REST access for the originating-issue fetch" >&2
    exit 1
  fi
  if ! JIRA_CONTEXT_PATH=$(_retro_jira_write_context "${ORIGINATING_NUMBER}"); then
    echo "ERROR: failed to fetch Jira issue ${ORIGINATING_NUMBER} for the retrospective" >&2
    exit 1
  fi
  # The harness marks the mount optional, so an empty file would mount nothing
  # and leave the agent to run on its own assumptions. Fail closed instead.
  if [[ ! -s "${JIRA_CONTEXT_PATH}" ]]; then
    echo "ERROR: Jira issue context file ${JIRA_CONTEXT_PATH} is missing or empty after the fetch" >&2
    exit 1
  fi
  echo "::notice::Jira issue context for ${ORIGINATING_NUMBER} written to ${JIRA_CONTEXT_PATH}"
fi

if [[ -n "${RETRO_COMMENT:-}" ]]; then
  echo "Retro triggered on-demand with comment."
else
  echo "Retro triggered automatically (PR close)."
fi

echo "Pre-retro validation complete."
