#!/usr/bin/env bash
# GENERATED from post-cve.src.sh — DO NOT EDIT. Run: make script-build
# post-cve.sh — DRAFT. Validate binding, publish the verdict, label.
#
# Runs on the host after the sandbox is gone. The agent's JSON has already
# passed schema validation (validation_loop). This script is the only thing
# that mutates the tracker (ADR: agents produce, post-scripts act).
#
# POST_CVE_DRY_RUN=1 prints the comment and labels instead of writing them.
#
# When the work item is a branch issue under a parent (lib/cve-fanout.lib.sh),
# the parent's sticky table is rebuilt from its children's labels. GitHub only.
#
# Labels (GitHub/Jira):
#   cve:affected | cve:not-affected | cve:fixed | cve:investigating | cve:failed
#   ready-to-code  only when CVE_AUTO_CODE=on AND status=known_affected AND
#                  remediation.plan_state=ready AND option != rebuild.
#                  The EXISTING code agent then implements the plan.

set -euo pipefail

: "${ISSUE_URL:?}" "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"
DRY_RUN="${POST_CVE_DRY_RUN:-}"   # non-empty: print what would happen, change nothing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/triage-ops.lib.sh
# BEGIN bundled: lib/triage-ops.lib.sh
# shellcheck shell=bash
# triage-ops.lib.sh — Tracker-dispatch wrapper for triage operations.
#
# Sources the correct tracker-specific ops based on FULLSEND_TRACKER
# (falling back to FULLSEND_FORGE if FULLSEND_TRACKER is unset).
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
TRIAGE_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"

case "${FULLSEND_TRACKER:-}" in
  github)
# BEGIN bundled: lib/github-triage-ops.lib.sh
# shellcheck shell=bash
# github-triage-ops.lib.sh — GitHub forge operations for triage scripts.
#
# Bundled into pre-triage.sh and post-triage.sh via triage-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by tracker_parse_issue_url):
#   REPO         — owner/repo (e.g., "org/repo")
#   ISSUE_NUMBER — issue number
#
# Expected env vars:
#   ISSUE_URL    — HTML URL of the issue
#   GH_TOKEN     — GitHub token with issues read/write scope

[[ -n "${GITHUB_TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_TRIAGE_OPS_SH_LOADED=1

# --- URL handling ---

tracker_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected pattern: ${ISSUE_URL}" >&2
    return 1
  fi
}

tracker_parse_issue_url() {
  REPO=$(echo "${ISSUE_URL}" | sed 's|https://github.com/||; s|/issues/.*||')
  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
}

# --- Labels ---

tracker_add_label() {
  local label="$1"
  local endpoint="repos/${REPO}/issues/${ISSUE_NUMBER}/labels"
  local err_output
  if ! err_output=$(gh api "${endpoint}" -f "labels[]=${label}" --silent 2>&1); then
    echo "ERROR: failed to add label '${label}' to issue #${ISSUE_NUMBER} (POST ${endpoint})" >&2
    [[ -n "${err_output}" ]] && echo "ERROR: ${err_output}" >&2
    return 1
  fi
}

tracker_remove_label() {
  local label="$1"
  local encoded
  encoded=$(printf '%s' "${label}" | jq -sRr @uri)
  gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/labels/${encoded}" -X DELETE --silent 2>/dev/null || true
}

tracker_strip_labels() {
  local labels=("$@")
  for label in "${labels[@]}"; do
    local encoded
    encoded=$(printf '%s' "${label}" | jq -sRr @uri)
    gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/labels/${encoded}" -X DELETE --silent 2>/dev/null || true
  done
}

tracker_verify_labels_stripped() {
  local labels=("$@")
  local labels_json
  labels_json=$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s .)

  local remaining
  remaining=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/labels" 2>/dev/null \
    | jq -r --argjson check "${labels_json}" \
        '[.[] | select(.name as $n | $check | index($n)) | .name] | join(", ")' \
    || echo "VERIFY_FAILED")

  if [[ "${remaining}" == "VERIFY_FAILED" ]]; then
    echo "ERROR: cannot verify label state — API call failed" >&2
    return 1
  fi
  if [[ -n "${remaining}" ]]; then
    echo "ERROR: triage labels still present after reset: ${remaining}" >&2
    return 1
  fi
}

tracker_list_repo_labels() {
  gh api "repos/${REPO}/labels" --paginate --jq '.[].name' 2>/dev/null || true
}

tracker_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  gh label create "${name}" --repo "${REPO}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

# Alias used by labels.lib.sh (forge_ensure_label delegates to forge_create_label).
forge_create_label() {
  tracker_create_label "$@"
}

# --- Comments ---

tracker_post_comment() {
  local body="$1"
  printf '%s' "${body}" | gh issue comment "${ISSUE_NUMBER}" --repo "${REPO}" --body-file -
}

tracker_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  printf '%s' "${body}" | fullsend post-comment --repo "${REPO}" --number "${ISSUE_NUMBER}" --marker "${marker}" --token "${GH_TOKEN}" --result -
}

# --- Issues ---

tracker_close_issue() {
  local reason="$1"
  gh issue close "${ISSUE_NUMBER}" --repo "${REPO}" --reason "${reason}"
}

tracker_create_issue() {
  local target_repo="$1"
  local title="$2"
  local body="$3"
  local err_file
  err_file=$(mktemp)
  local url
  if ! url=$(gh issue create --repo "${target_repo}" --title "${title}" --body "${body}" 2>"${err_file}"); then
    local err_msg
    err_msg=$(cat "${err_file}")
    rm -f "${err_file}"
    echo "GitHub API error: failed to create issue in ${target_repo}: ${err_msg}" >&2
    return 1
  fi
  rm -f "${err_file}"
  echo "${url}"
}

# Apply ready-for-triage to a newly created issue so the dispatch shim
# picks it up. issues.opened from a workflow-driven create may not start
# a new run; issues.labeled does. Failures are non-fatal for the caller.
#
# target_repo must be the same already-allowlisted repo (checked via
# is_target_allowed) that created_url's issue was created in. Mutating
# against target_repo directly — rather than re-deriving the repo by
# parsing created_url — avoids trusting an unvalidated/unanchored parse
# of forge-returned text to pick which repo gets a label mutation.
tracker_dispatch_triage() {
  local created_url="$1"
  local target_repo="$2"
  local saved_repo="${REPO}"
  local saved_number="${ISSUE_NUMBER}"
  REPO="${target_repo}"
  ISSUE_NUMBER=$(basename "${created_url}")
  # Ensure the label exists in the target repo (needed for cross-repo splits).
  tracker_create_label "ready-for-triage" "Triggers triage agent dispatch" "0E8A16"
  local rc=0
  if ! tracker_add_label "ready-for-triage"; then
    echo "::warning::Failed to add ready-for-triage label to $(_gha_sanitize "${created_url}")" >&2
    rc=1
  fi
  REPO="${saved_repo}"
  ISSUE_NUMBER="${saved_number}"
  return "${rc}"
}
# END bundled: lib/github-triage-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-triage-ops.lib.sh
# shellcheck shell=bash
# gitlab-triage-ops.lib.sh — GitLab forge operations for triage scripts.
#
# Bundled into pre-triage.sh and post-triage.sh via triage-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by tracker_parse_issue_url):
#   REPO           — plain project path (e.g., "group/project")
#   REPO_ENCODED   — URL-encoded project path (e.g., "group%2Fproject")
#   ISSUE_NUMBER   — issue IID
#   GITLAB_HOST    — API host (e.g., "gitlab.com")
#
# Expected env vars:
#   ISSUE_URL      — HTML URL of the issue
#   GITLAB_TOKEN   — GitLab personal/project access token
#   CI_SERVER_HOST — GitLab CI predefined variable (set by runner)
#   CI_SERVER_URL  — GitLab CI predefined variable; API origin, including
#                    any non-default port (falls back to
#                    https://${CI_SERVER_HOST} when unset)
#
# Token scopes: GITLAB_TOKEN requires minimum scopes:
#   - api (read/write issues, labels, notes, merge requests)
#   Prefer project access tokens scoped to the target project over
#   personal access tokens with broader access.
#
# Token identity: GITLAB_TOKEN must resolve to an identity the fullsend
# GitLab dispatcher's bot detection recognizes (project access token or
# configured bot user). Label writes use PUT /issues/:iid which bumps
# updated_at; the dispatcher's isBotEvent filter prevents re-triggering
# triage only if the token owner is recognized as a bot.

[[ -n "${GITLAB_TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_TRIAGE_OPS_SH_LOADED=1

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
    echo "ERROR: GITLAB_HOST is not set — call tracker_parse_issue_url first" >&2
    return 1
  fi
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
  local origin
  origin=$(_gitlab_trusted_origin) || return 1
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "${origin}/api/v4${endpoint}" \
    "$@"
}

_gitlab_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call tracker_parse_issue_url first" >&2
    return 1
  fi
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
  local origin
  origin=$(_gitlab_trusted_origin) || return 1
  local err_file
  err_file=$(mktemp)
  local raw
  raw=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${origin}/api/v4${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "GitLab API error: curl failed — $(cat "${err_file}")" >&2
    rm -f "${err_file}"
    return 1
  }
  rm -f "${err_file}"
  local http_code
  http_code=$(echo "${raw}" | tail -1)
  local body
  body=$(echo "${raw}" | sed '$d')
  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    echo "GitLab API error (HTTP ${http_code}): ${body}" >&2
    return 1
  fi
  echo "${body}"
}

# --- URL handling ---

tracker_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^(https://[a-zA-Z0-9._-]+(:[0-9]+)?)(/[a-zA-Z0-9._-]+)+/-/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitLab pattern: $(_gha_sanitize "${ISSUE_URL}")" >&2
    return 1
  fi
  local origin="${BASH_REMATCH[1]}"
  _validate_gitlab_origin "${origin}" || return 1
}

tracker_parse_issue_url() {
  # Extract host, project path, and issue IID from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/issues/42
  # The port, if any, is checked by tracker_validate_issue_url; GITLAB_HOST
  # holds the hostname only and API requests use the trusted CI origin.
  GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/:]+)(:[0-9]+)?/.*|\1|')
  REPO=$(echo "${ISSUE_URL}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
  REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
}

# --- Labels ---

tracker_add_label() {
  local label="$1"
  if ! _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "add_labels=${label}" > /dev/null; then
    echo "ERROR: failed to add label '${label}' to issue #${ISSUE_NUMBER} via PUT /projects/${REPO}/issues/${ISSUE_NUMBER}" >&2
    return 1
  fi
}

tracker_remove_label() {
  local label="$1"
  _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "remove_labels=${label}" > /dev/null 2>/dev/null || true
}

tracker_strip_labels() {
  local labels=("$@")
  for label in "${labels[@]}"; do
    _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" \
      --data-urlencode "remove_labels=${label}" > /dev/null 2>/dev/null || true
  done
}

tracker_verify_labels_stripped() {
  local labels=("$@")
  local current_labels
  current_labels=$(_gitlab_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" 2>/dev/null | jq -r '[.labels[]] | join(",")' 2>/dev/null || echo "VERIFY_FAILED")

  if [[ "${current_labels}" == "VERIFY_FAILED" ]]; then
    echo "ERROR: cannot verify label state — API call failed" >&2
    return 1
  fi

  local remaining=""
  IFS=',' read -ra current_array <<< "${current_labels}"
  for current in "${current_array[@]}"; do
    for check in "${labels[@]}"; do
      if [[ "${current}" == "${check}" ]]; then
        if [[ -n "${remaining}" ]]; then
          remaining="${remaining}, ${current}"
        else
          remaining="${current}"
        fi
      fi
    done
  done

  if [[ -n "${remaining}" ]]; then
    echo "ERROR: triage labels still present after reset: ${remaining}" >&2
    return 1
  fi
}

tracker_list_repo_labels() {
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

tracker_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  _gitlab_api POST "/projects/${REPO_ENCODED}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${color}" > /dev/null 2>/dev/null || true
}

# Alias used by labels.lib.sh (forge_ensure_label delegates to forge_create_label).
forge_create_label() {
  tracker_create_label "$@"
}

# --- Bot identity (for sticky-comment author filtering) ---

_GITLAB_BOT_USERNAME=""

_gitlab_bot_username() {
  if [[ -z "${_GITLAB_BOT_USERNAME}" ]]; then
    _GITLAB_BOT_USERNAME=$(_gitlab_api GET "/user" 2>/dev/null | jq -r '.username // empty')
    if [[ -z "${_GITLAB_BOT_USERNAME}" ]]; then
      echo "ERROR: failed to determine GitLab token owner via GET /user" >&2
      return 1
    fi
  fi
  echo "${_GITLAB_BOT_USERNAME}"
}

# --- Comments (notes in GitLab) ---

tracker_post_comment() {
  local body="$1"
  _gitlab_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
    --data-urlencode "body=${body}" > /dev/null
}

tracker_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  local marked_body="${marker}
${body}"

  local bot_user
  bot_user=$(_gitlab_bot_username) || {
    _gitlab_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
      --data-urlencode "body=${marked_body}" > /dev/null
    return
  }

  local notes="[]"
  local page=1 max_pages=50
  while [[ "${page}" -le "${max_pages}" ]]; do
    local batch
    batch=$(_gitlab_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=asc&page=${page}" 2>/dev/null) || break
    local count
    count=$(echo "${batch}" | jq 'length') || break
    [[ "${count}" -eq 0 ]] && break
    notes=$(echo "${notes}" "${batch}" | jq -s 'add')
    page=$((page + 1))
  done

  local match
  match=$(echo "${notes}" | jq --arg marker "${marker}" --arg user "${bot_user}" \
    '[.[] | select(.author.username == $user and (.body | startswith($marker)))][0] // empty')

  local note_id
  note_id=$(echo "${match}" | jq -r '.id // empty')

  if [[ -n "${note_id}" ]]; then
    local old_body
    old_body=$(echo "${match}" | jq -r '.body // empty')
    local stripped_old
    local escaped_marker
    escaped_marker=$(printf '%s' "${marker}" | sed 's/[].[*^$()+?{|\\]/\\&/g; s|/|\\/|g')
    stripped_old=$(echo "${old_body}" | sed "1{/^${escaped_marker}$/d;}")
    if [[ -n "${stripped_old}" ]]; then
      local history
      history=$(printf '\n\n<details>\n<summary>Previous run</summary>\n\n%s\n\n</details>' "${stripped_old}")
      local max_len=60000
      if [[ ${#history} -gt ${max_len} ]]; then
        history="${history:0:${max_len}}
...(truncated)"
      fi
      marked_body="${marked_body}${history}"
    fi
    _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes/${note_id}" \
      --data-urlencode "body=${marked_body}" > /dev/null
  else
    _gitlab_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
      --data-urlencode "body=${marked_body}" > /dev/null
  fi
}

# --- Issues ---

tracker_close_issue() {
  local _reason="$1"  # GitLab has no close-reason API; accepted for interface parity
  if ! _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" \
    --data-urlencode "state_event=close" > /dev/null; then
    echo "ERROR: failed to close issue #${ISSUE_NUMBER} in ${REPO}" >&2
    return 1
  fi
}

tracker_create_issue() {
  local target_repo="$1"
  local title="$2"
  local body="$3"
  local encoded_target
  encoded_target=$(printf '%s' "${target_repo}" | jq -sRr @uri)
  local response
  response=$(_gitlab_api_with_status POST "/projects/${encoded_target}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description=${body}") || {
    echo "GitLab API error: failed to create issue in ${target_repo}" >&2
    return 1
  }
  echo "${response}" | jq -r '.web_url'
}

# Apply ready-for-triage to a newly created issue so GitLab dispatch
# picks it up. Uses _gitlab_api (host-allowlisted) against target_repo —
# the same already-allowlisted project (checked via is_target_allowed)
# that created_url's issue was created in — rather than re-deriving the
# project by parsing created_url, which would trust an unvalidated parse
# of forge-returned text to pick which project gets a label mutation.
tracker_dispatch_triage() {
  local created_url="$1"
  local target_repo="$2"
  local saved_repo="${REPO}"
  local saved_encoded="${REPO_ENCODED}"
  local saved_number="${ISSUE_NUMBER}"
  REPO="${target_repo}"
  REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
  ISSUE_NUMBER=$(basename "${created_url}")
  local rc=0
  if ! tracker_add_label "ready-for-triage"; then
    echo "::warning::Failed to add ready-for-triage label to $(_gha_sanitize "${created_url}")" >&2
    rc=1
  fi
  REPO="${saved_repo}"
  REPO_ENCODED="${saved_encoded}"
  ISSUE_NUMBER="${saved_number}"
  return "${rc}"
}
# END bundled: lib/gitlab-triage-ops.lib.sh
    ;;
  jira)
# BEGIN bundled: lib/jira-triage-ops.lib.sh
# shellcheck shell=bash
# jira-triage-ops.lib.sh — Jira Cloud tracker operations for triage scripts.
#
# Bundled into pre-triage.sh and post-triage.sh via triage-ops.lib.sh.
# Labels, transitions, and cross-project issue creation use curl against
# the Jira Cloud REST API v3. Comment posting shells out to
# `fullsend issues post-comment --tracker jira`, which handles Jira's
# markdown-to-ADF conversion and marker-based find-and-update semantics
# that raw REST calls would otherwise have to reimplement.
#
# Jira Cloud only (v1): the issue host must match *.atlassian.net. Jira
# Server/Data Center is not supported.
#
# Expected globals (set by tracker_parse_issue_url):
#   REPO           — Jira project key (e.g., "PROJ")
#   ISSUE_NUMBER   — full Jira issue key (e.g., "PROJ-123")
#   JIRA_ISSUE_NUM — numeric issue suffix (e.g., "123"), for the
#                    `fullsend issues` CLI's --number flag
#   JIRA_BASE_URL  — Jira instance base URL (e.g., "https://myteam.atlassian.net")
#
# Expected env vars:
#   ISSUE_URL       — HTML URL of the issue (https://<host>.atlassian.net/browse/PROJ-123)
#   JIRA_TOKEN      — Jira API token (the triage harness maps
#                     FULLSEND_JIRA_TOKEN to it)
#   JIRA_USER_EMAIL — (optional) bot-user email (the triage harness maps
#                     FULLSEND_JIRA_EMAIL to it). When set, requests use
#                     Basic auth with email and token; when unset or
#                     empty, Bearer auth with a service-account token.
#                     See lib/jira-auth.lib.sh.
#   FULLSEND_DIR    — .fullsend directory whose config.yaml holds
#                     tracker.jira, for the `fullsend issues` shell-outs
#   JIRA_API_URL    — (optional) where REST calls go, e.g. the Atlassian
#                     API gateway https://api.atlassian.com/ex/jira/<cloudId>
#                     that `fullsend run` resolves and exports. Falls back
#                     to JIRA_BASE_URL when unset (older fullsend releases).
#                     Browse links always use JIRA_BASE_URL.
#
# The `fullsend issues` CLI reads its credentials from FULLSEND_JIRA_TOKEN
# and, for a bot user, FULLSEND_JIRA_EMAIL, and its Jira site and API
# gateway from tracker.jira in --fullsend-dir. jira_auth_fullsend passes
# the same token and email to it, so one set of credentials covers both
# the raw REST calls in this file and the `fullsend` shell-outs below.
#
# Optional env vars:
#   JIRA_DUPLICATE_TRANSITION   — transition name for the "duplicate" action
#   JIRA_NOT_PLANNED_TRANSITION — transition name for the "not planned" action
#   JIRA_SPLIT_TRANSITION       — transition name for the "split" and
#                                 "completed" actions (both close with
#                                 GitHub reason "completed")
#   JIRA_CREATE_ISSUE_TYPE      — issue type name for cross-project issue
#                                 creation (default: "Task")

[[ -n "${JIRA_TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
JIRA_TRIAGE_OPS_SH_LOADED=1

# Validate credentials at source time — fails once, early, on unredirected
# stderr, before any call site can swallow the diagnostic with 2>/dev/null.
# Matches the idiom pre-triage.src.sh / post-triage.src.sh already use for
# ISSUE_URL and FULLSEND_TRACKER.
# JIRA_USER_EMAIL is optional: without it, requests use Bearer auth.
: "${JIRA_TOKEN:?JIRA_TOKEN must be set}"

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
# JIRA_API_URL is optional, but the credentials are sent to it, so refuse
# anything that is not https.
if [[ -n "${JIRA_API_URL:-}" && "${JIRA_API_URL}" != https://* ]]; then
  echo "ERROR: JIRA_API_URL must start with https://" >&2
  exit 1
fi

# JIRA_BASE_URL is derived at runtime by tracker_parse_issue_url, so it
# cannot be validated at source time — keep a per-call guard for it.
_jira_require_vars() {
  if [[ -z "${JIRA_BASE_URL:-}" ]]; then echo "ERROR: JIRA_BASE_URL is not set" >&2; return 1; fi
}

# Print the base URL for REST calls: JIRA_API_URL when set, else
# JIRA_BASE_URL, with trailing slash(es) stripped.
_jira_api_base() {
  local base="${JIRA_API_URL:-${JIRA_BASE_URL}}"
  while [[ "${base}" == */ ]]; do
    base="${base%/}"
  done
  printf '%s\n' "${base}"
}

_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift

  _jira_require_vars || return 1
  local api_base
  api_base=$(_jira_api_base) || return 1

  jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --request "${method}" \
    "${api_base}/rest/api/3${endpoint}" \
    "$@"
}

_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift

  _jira_require_vars || return 1
  local api_base
  api_base=$(_jira_api_base) || return 1

  local err_file
  err_file=$(mktemp)
  local raw
  raw=$(jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${api_base}/rest/api/3${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "Jira API error: curl failed — $(cat "${err_file}")" >&2
    rm -f "${err_file}"
    return 1
  }
  rm -f "${err_file}"
  local http_code
  http_code=$(echo "${raw}" | tail -1)
  local body
  body=$(echo "${raw}" | sed '$d')
  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    echo "Jira API error (HTTP ${http_code}): ${body}" >&2
    return 1
  fi
  echo "${body}"
}

# --- URL handling ---

tracker_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected Jira pattern: ${ISSUE_URL}" >&2
    return 1
  fi
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  case "${host}" in
    *.atlassian.net) ;;
    *) echo "ERROR: Jira host '${host}' is not in the allowed host list" >&2; return 1 ;;
  esac
}

tracker_parse_issue_url() {
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  local parsed_base_url="https://${host}"
  # Strip trailing slash(es) from JIRA_BASE_URL so that a copy-pasted
  # "https://acme.atlassian.net/" matches the parsed "https://acme.atlassian.net".
  # Loop rather than a single ${VAR%/} so that "…net//" normalises too.
  while [[ -n "${JIRA_BASE_URL:-}" && "${JIRA_BASE_URL}" == */ ]]; do
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"
  done
  if [[ -n "${JIRA_BASE_URL:-}" ]] && [[ "${JIRA_BASE_URL}" != "${parsed_base_url}" ]]; then
    echo "ERROR: JIRA_BASE_URL ('${JIRA_BASE_URL}') does not match ISSUE_URL host ('${parsed_base_url}') — refusing to redirect API calls to a different tenant" >&2
    return 1
  fi
  JIRA_BASE_URL="${parsed_base_url}"
  ISSUE_NUMBER=$(echo "${ISSUE_URL}" | sed -E 's|.*/browse/||')
  REPO="${ISSUE_NUMBER%-*}"
  JIRA_ISSUE_NUM="${ISSUE_NUMBER##*-}"
}

# --- Labels ---

tracker_add_label() {
  local label="$1"
  if ! _jira_api PUT "/issue/${ISSUE_NUMBER}" \
    --data "$(jq -cn --arg l "${label}" '{update:{labels:[{add:$l}]}}')" > /dev/null; then
    echo "ERROR: failed to add label '${label}' to issue ${ISSUE_NUMBER} via PUT /issue/${ISSUE_NUMBER}" >&2
    return 1
  fi
}

tracker_remove_label() {
  local label="$1"
  # Jira treats removing an absent label as a no-op, so an error here is a
  # real write failure. Fail the step instead of reporting success.
  if ! _jira_api PUT "/issue/${ISSUE_NUMBER}" \
    --data "$(jq -cn --arg l "${label}" '{update:{labels:[{remove:$l}]}}')" > /dev/null; then
    echo "ERROR: failed to remove label '${label}' from issue ${ISSUE_NUMBER} via PUT /issue/${ISSUE_NUMBER}" >&2
    return 1
  fi
}

tracker_strip_labels() {
  local labels=("$@")
  for label in "${labels[@]}"; do
    _jira_api PUT "/issue/${ISSUE_NUMBER}" \
      --data "$(jq -cn --arg l "${label}" '{update:{labels:[{remove:$l}]}}')" > /dev/null 2>/dev/null || true
  done
}

tracker_verify_labels_stripped() {
  local labels=("$@")
  local raw_labels
  raw_labels=$(_jira_api GET "/issue/${ISSUE_NUMBER}?fields=labels" 2>/dev/null) || {
    echo "ERROR: cannot verify label state — API call failed" >&2
    return 1
  }

  # An unparseable body must not read as "no labels remaining" — parse it up
  # front so a bad shape fails loudly, matching the GitHub/GitLab sentinel.
  local current_labels
  current_labels=$(echo "${raw_labels}" | jq -r '[.fields.labels[]] | join("\n")' 2>/dev/null) \
    || current_labels="VERIFY_FAILED"
  if [[ "${current_labels}" == "VERIFY_FAILED" ]]; then
    echo "ERROR: cannot verify label state — unexpected response shape" >&2
    return 1
  fi

  local remaining=""
  local current
  while IFS= read -r current; do
    [[ -z "${current}" ]] && continue
    for check in "${labels[@]}"; do
      if [[ "${current}" == "${check}" ]]; then
        if [[ -n "${remaining}" ]]; then
          remaining="${remaining}, ${current}"
        else
          remaining="${current}"
        fi
      fi
    done
  done <<< "${current_labels}"

  if [[ -n "${remaining}" ]]; then
    echo "ERROR: triage labels still present after reset: ${remaining}" >&2
    return 1
  fi
}

# Jira has no per-project label registry like GitHub/GitLab — any string is
# a valid label with no creation step. As the closest analog to "labels the
# maintainers already established" (which the "will not auto-create" guard
# in post-triage.src.sh relies on), this lists labels already used anywhere
# in the Jira site via the global label-suggestion endpoint.
tracker_list_repo_labels() {
  local start_at=0 max_pages=50
  for _ in $(seq 1 "${max_pages}"); do
    local batch
    batch=$(_jira_api GET "/label?startAt=${start_at}&maxResults=200" 2>/dev/null) || break
    local count
    count=$(echo "${batch}" | jq '.values | length') || break
    [[ "${count}" -eq 0 ]] && break
    echo "${batch}" | jq -r '.values[]'
    if [[ "$(echo "${batch}" | jq -r '.isLast')" == "true" ]]; then
      break
    fi
    start_at=$((start_at + count))
  done
}

# Jira has no label-creation step (see tracker_list_repo_labels) — adding an
# unused label to an issue works without registering it first.
tracker_create_label() {
  :
}

# Alias used by labels.lib.sh (forge_ensure_label delegates to forge_create_label).
forge_create_label() {
  tracker_create_label "$@"
}

# --- Components ---

# Set components on a Jira issue. Accepts a JSON array of component objects
# (e.g., [{"name":"backend"},{"name":"frontend"}]) and replaces the issue's
# component list with that set.
tracker_set_components() {
  local components_json="$1"
  if ! _jira_api PUT "/issue/${ISSUE_NUMBER}" \
    --data "$(jq -cn --argjson c "${components_json}" '{fields:{components:$c}}')" > /dev/null; then
    echo "ERROR: failed to set components on issue ${ISSUE_NUMBER} via PUT /issue/${ISSUE_NUMBER}" >&2
    return 1
  fi
}

# Get current components on a Jira issue. Returns a JSON array of component
# name strings (e.g., ["backend","frontend"]).
tracker_get_components() {
  local response
  response=$(_jira_api GET "/issue/${ISSUE_NUMBER}?fields=components" 2>/dev/null) || {
    echo "ERROR: failed to get components for issue ${ISSUE_NUMBER}" >&2
    return 1
  }
  echo "${response}" | jq -r '[(.fields.components // [])[].name]'
}

# --- Comments ---

tracker_post_comment() {
  local body="$1"
  _jira_require_vars || return 1
  # `fullsend issues post-comment` always does marker-based find-and-update;
  # there is no "always create new" mode. Each triage run gets a new comment,
  # matching tracker_post_comment's always-new contract on GitHub/GitLab.
  # The marker is scoped to the CI run (GITHUB_RUN_ID survives a workflow
  # re-run, CI_PIPELINE_ID a GitLab job retry), so a retried run edits its
  # own earlier comment instead of posting a duplicate.
  local marker stamp
  local run_id="${GITHUB_RUN_ID:-${CI_PIPELINE_ID:-}}"
  if [[ "${run_id}" =~ ^[0-9]+$ ]]; then
    marker="<!-- fullsend:triage-run-${run_id} -->"
  else
    # No CI run ID: a marker unique to this invocation guarantees no prior
    # comment matches it.
    stamp=$(date +%s%N)
    # BSD date without %N support leaves the literal "N" in place, which would
    # make the marker identical for every invocation within the same second and
    # break the always-create-new contract. Fall back to a random suffix.
    if [[ "${stamp}" == *N* ]]; then
      stamp="$(date +%s)${RANDOM}${RANDOM}"
    fi
    marker="<!-- fullsend:triage-${stamp} -->"
  fi
  _jira_post_comment "${body}" "${marker}"
}

tracker_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  _jira_require_vars || return 1
  _jira_post_comment "${body}" "${marker}"
}

# Post or update the comment carrying <marker> through the fullsend CLI,
# which takes the Jira site and API gateway from tracker.jira in
# FULLSEND_DIR's config.yaml and the credentials from its environment.
_jira_post_comment() {
  local body="$1"
  local marker="$2"
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${REPO}" --number "${JIRA_ISSUE_NUM}" \
    --marker "${marker}" --result -
}

# --- Issues ---

tracker_close_issue() {
  local reason="$1"
  local transition_var
  case "${reason}" in
    duplicate) transition_var="JIRA_DUPLICATE_TRANSITION" ;;
    "not planned") transition_var="JIRA_NOT_PLANNED_TRANSITION" ;;
    completed) transition_var="JIRA_SPLIT_TRANSITION" ;;
    *)
      echo "ERROR: unknown close reason '${reason}' — no Jira transition mapping" >&2
      return 1
      ;;
  esac

  local transition_name="${!transition_var:-}"
  if [[ -z "${transition_name}" ]]; then
    echo "ERROR: ${transition_var} is not set — cannot close issue ${ISSUE_NUMBER} via Jira transition for reason '${reason}'" >&2
    return 1
  fi

  local transitions
  transitions=$(_jira_api GET "/issue/${ISSUE_NUMBER}/transitions" 2>/dev/null) || {
    echo "ERROR: failed to list transitions for issue ${ISSUE_NUMBER}" >&2
    return 1
  }
  local transition_id
  transition_id=$(echo "${transitions}" | jq -r --arg name "${transition_name}" \
    '[.transitions[] | select(.name == $name)][0].id // empty')
  if [[ -z "${transition_id}" ]]; then
    echo "ERROR: transition '${transition_name}' (from ${transition_var}) is not available on issue ${ISSUE_NUMBER}" >&2
    return 1
  fi

  if ! _jira_api POST "/issue/${ISSUE_NUMBER}/transitions" \
    --data "$(jq -cn --arg id "${transition_id}" '{transition:{id:$id}}')" > /dev/null; then
    echo "ERROR: failed to transition issue ${ISSUE_NUMBER} via '${transition_name}'" >&2
    return 1
  fi
}

_text_to_adf() {
  # Convert plain text to Atlassian Document Format (ADF) JSON.
  # Splits on blank lines into separate paragraphs; within a paragraph,
  # single newlines become hardBreak nodes.
  local text="$1"
  jq -cn --arg text "${text}" '
    # Split into paragraphs on blank lines (two or more consecutive newlines).
    ($text | split("\n\n")) as $paragraphs |
    {
      type: "doc",
      version: 1,
      content: [
        $paragraphs[] |
        select(length > 0) |
        # Split each paragraph on single newlines and interleave hardBreak nodes.
        (split("\n") | map(select(length > 0))) as $lines |
        select(($lines | length) > 0) |
        {
          type: "paragraph",
          content: (
            reduce $lines[] as $line (
              {idx: 0, nodes: []};
              if .idx > 0 then
                .nodes += [{type: "hardBreak"}, {type: "text", text: $line}]
              else
                .nodes += [{type: "text", text: $line}]
              end | .idx += 1
            ) | .nodes
          )
        }
      ]
    }
  '
}

tracker_create_issue() {
  local target_repo="$1"
  local title="$2"
  local body="$3"
  local issue_type="${JIRA_CREATE_ISSUE_TYPE:-Task}"
  # Jira Cloud REST v3 requires the description as Atlassian Document
  # Format, not plain text/markdown. Multi-line bodies are split into
  # ADF paragraphs (on blank lines) with hardBreak nodes for single
  # newlines within a paragraph.
  local description_adf
  description_adf=$(_text_to_adf "${body}")
  local response
  response=$(_jira_api_with_status POST "/issue" \
    --data "$(jq -cn --arg proj "${target_repo}" --arg title "${title}" \
      --arg itype "${issue_type}" --argjson desc "${description_adf}" \
      '{fields:{project:{key:$proj},summary:$title,description:$desc,issuetype:{name:$itype}}}')") || {
    echo "Jira API error: failed to create issue in ${target_repo}" >&2
    return 1
  }
  local key
  key=$(echo "${response}" | jq -r '.key // empty' 2>/dev/null)
  if [[ -z "${key}" ]]; then
    echo "ERROR: Jira create-issue response for ${target_repo} contained no issue key" >&2
    return 1
  fi
  echo "${JIRA_BASE_URL}/browse/${key}"
}

# Apply ready-for-triage to a newly created issue so Jira dispatch can
# pick it up. Failures are non-fatal for the caller.
#
# target_project must be the same already-allowlisted project key (checked
# via is_target_allowed) that created_url's issue was created in. Unlike
# GitHub/GitLab, the issue key used to address the label PUT (not just a
# REPO global) has to be derived from created_url, so this validates the
# URL against the same anchored pattern tracker_validate_issue_url uses and
# then rebuilds the issue key from target_project plus only the numeric
# suffix of created_url — rather than trusting the project name parsed out
# of created_url — before mutating.
tracker_dispatch_triage() {
  local created_url="$1"
  local target_project="$2"
  local saved_number="${ISSUE_NUMBER}"
  if [[ ! "${created_url}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    echo "ERROR: created_url does not match expected Jira pattern: $(_gha_sanitize "${created_url}")" >&2
    return 1
  fi
  local parsed_key="${created_url##*/browse/}"
  if [[ -n "${target_project}" ]]; then
    # Rebuild the issue key from the already-allowlisted target project
    # plus only the numeric suffix from created_url, rather than trusting
    # the project name parsed out of created_url.
    ISSUE_NUMBER="${target_project}-${parsed_key##*-}"
  else
    ISSUE_NUMBER="${parsed_key}"
  fi
  local rc=0
  if ! tracker_add_label "ready-for-triage"; then
    echo "::warning::Failed to add ready-for-triage label to $(_gha_sanitize "${created_url}")" >&2
    rc=1
  fi
  ISSUE_NUMBER="${saved_number}"
  return "${rc}"
}
# END bundled: lib/jira-triage-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_TRACKER: '${FULLSEND_TRACKER:-}' — pass --tracker <github|gitlab|jira> or set FULLSEND_TRACKER" >&2
    exit 1
    ;;
esac
# END bundled: lib/triage-ops.lib.sh
# shellcheck source=lib/cve-fanout.lib.sh
# BEGIN bundled: lib/cve-fanout.lib.sh
# shellcheck shell=bash
# cve-fanout.lib.sh — DRAFT. One vulnerability, several maintained branches.
#
# Fan-out: a parent work item becomes one child issue per maintained branch.
# Each child is an ordinary single-target cve run, then an ordinary code-agent
# run, so nothing here adds a workflow engine. Fan-in: a sticky table on the
# parent, rebuilt from the children's labels every time one of them finishes.
# No state is stored anywhere but the issues: each run reads them and
# finishes what is missing.
#
# Everything here is deterministic host code. The model never chooses the
# branches and never sees the parent or its siblings.
#
# Adopter configuration (runner env, exact branch names, comma-separated):
#   CVE_BRANCHES         maintained branches. Empty = single-branch mode.
#   CVE_BRANCHES_FOLLOW  branches that are still synced from another branch
#                        and must not receive a change of their own. They get
#                        no child issue; the table lists them as following.
#
# GitHub only. A Jira tracker is already one-per-stream; it names its branch
# in the `cve-intake` property and is never fanned out here.

[[ -n "${CVE_FANOUT_SH_LOADED:-}" ]] && return 0
CVE_FANOUT_SH_LOADED=1

CVE_BRANCH_RE='^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$'

# cve_branch_list "a, b,c" → one branch per line. An invalid name is an error:
# a typo in configuration must not silently drop a release branch.
cve_branch_list() {
  local raw="$1" b
  local -a parts
  IFS=',' read -r -a parts <<<"${raw}"
  for b in "${parts[@]}"; do
    b="${b#"${b%%[![:space:]]*}"}"
    b="${b%"${b##*[![:space:]]}"}"
    [[ -z "${b}" ]] && continue
    if [[ ! "${b}" =~ ${CVE_BRANCH_RE} || "${b}" == *..* ]]; then
      echo "::error::cve: invalid branch name in the configured branch list" >&2
      return 1
    fi
    printf '%s\n' "${b}"
  done
}

# cve_branch_in NAME "a,b" → 0 when NAME is in the list.
cve_branch_in() {
  [[ -n "${2:-}" ]] || return 1
  # No pipe into `grep -q`: it exits on the first match, the writer then dies
  # of SIGPIPE, and under `pipefail` a match is reported as a miss.
  local list b
  list=$(cve_branch_list "$2") || return 1
  while IFS= read -r b; do
    [[ "${b}" == "$1" ]] && return 0
  done <<<"${list}"
  return 1
}

# cve_fanout REPO PARENT_NUMBER FINDING_JSON VULN_ID [DRY]
# Brings the parent's branch issues to the wanted state: one issue per branch
# in CVE_BRANCHES that is not in CVE_BRANCHES_FOLLOW, linked under the parent
# and carrying the `cve` label. The label is added last, in its own call, so
# it arrives as a label event. Sets CVE_FANOUT_SUMMARY.
#
# It keeps no record of its own. Every run reads what exists and finishes
# whatever is missing, so a run that died part-way is completed by the next:
#   - linked child, matched by its host-written title      → nothing to create
#   - created but never linked (found by the `cve-branch`
#     label that is set in the create call itself)         → link it
#   - linked or adopted but never given the `cve` label     → add the label
# Both lookups are list calls, never search, whose results lag. An unlinked
# issue is adopted, and a missing label repaired, only when a bot wrote the
# issue: a person cannot plant a branch issue for the agent to pick up.
cve_fanout() {
  local repo="$1" parent="$2" finding="$3" id="$4" dry="${5:-}"
  local linked orphans b title hit block body child cid cnum
  local created=0 followed=0 present=0 repaired=0
  local pick='{id, number, state, bot: ((.user.type // "") == "Bot"), labelled: any((.labels // [])[]; .name | test("^cve(:|$)"))}'

  linked=$(gh api "repos/${repo}/issues/${parent}/sub_issues?per_page=100") || return 1
  orphans=$(gh api "repos/${repo}/issues?labels=cve-branch&state=all&per_page=100") || return 1

  while IFS= read -r b; do
    [[ -z "${b}" ]] && continue
    if cve_branch_in "${b}" "${CVE_BRANCHES_FOLLOW:-}"; then
      followed=$((followed + 1))
      continue
    fi
    title="${id}: ${b}"

    hit=$(jq -c --arg t "${title}" "[.[] | select(.title == \$t)] | first // empty | ${pick}" <<<"${linked}")
    if [[ -n "${hit}" ]]; then
      present=$((present + 1))
      if [[ "$(jq -r '.bot and (.labelled | not) and .state == "open"' <<<"${hit}")" == "true" ]]; then
        cnum=$(jq -r '.number' <<<"${hit}")
        if [[ -n "${dry}" ]]; then
          echo "cve (dry run): would label unfinished branch issue #${cnum} '${title}'"
        else
          gh api "repos/${repo}/issues/${cnum}/labels" -f "labels[]=cve" --silent || return 1
        fi
        repaired=$((repaired + 1))
      fi
      continue
    fi

    hit=$(jq -c --arg t "${title}" \
      "[.[] | select(.title == \$t and (.pull_request | not) and (.user.type // \"\") == \"Bot\")] | first // empty | ${pick}" <<<"${orphans}")
    if [[ -n "${hit}" ]]; then
      cid=$(jq -r '.id' <<<"${hit}"); cnum=$(jq -r '.number' <<<"${hit}")
      if [[ -n "${dry}" ]]; then
        echo "cve (dry run): would link unfinished branch issue #${cnum} '${title}' under #${parent}"
      else
        gh api "repos/${repo}/issues/${parent}/sub_issues" -F "sub_issue_id=${cid}" --silent || return 1
        gh api "repos/${repo}/issues/${cnum}/labels" -f "labels[]=cve" --silent || return 1
      fi
      repaired=$((repaired + 1))
      continue
    fi

    # Built from the validated finding only: no parent title, body or comment.
    block=$(jq -c --arg ref "${b}" \
      '{vulnerability: .vulnerability, package: (.package // {}), source: {kind: .source.kind}, target: {ref: $ref}}' \
      "${finding}")
    body=$(printf 'Branch issue for %s on `%s`. Tracked by #%s.\n\n```cve-finding\n%s\n```\n' \
      "${id}" "${b}" "${parent}" "${block}")
    if [[ -n "${dry}" ]]; then
      echo "cve (dry run): would create branch issue '${title}' under #${parent}"
      created=$((created + 1))
      continue
    fi
    child=$(gh api "repos/${repo}/issues" -f "title=${title}" -f "body=${body}" -f "labels[]=cve-branch") || return 1
    cid=$(jq -r '.id' <<<"${child}")
    cnum=$(jq -r '.number' <<<"${child}")
    [[ "${cid}" =~ ^[0-9]+$ && "${cnum}" =~ ^[0-9]+$ ]] || { echo "::error::cve: issue create returned no id" >&2; return 1; }
    gh api "repos/${repo}/issues/${parent}/sub_issues" -F "sub_issue_id=${cid}" --silent || return 1
    gh api "repos/${repo}/issues/${cnum}/labels" -f "labels[]=cve" --silent || return 1
    created=$((created + 1))
  done < <(cve_branch_list "${CVE_BRANCHES:-}")

  if [[ ${created} -eq 0 && ${repaired} -eq 0 ]]; then
    CVE_FANOUT_SUMMARY="${id} is already fanned out (${present} branch issue(s)); nothing to do on the parent"
  elif [[ ${created} -eq 0 ]]; then
    CVE_FANOUT_SUMMARY="${id} fan-out completed: ${repaired} unfinished branch issue(s) repaired"
  else
    CVE_FANOUT_SUMMARY="${id} fanned out to ${created} branch issue(s)"
    [[ ${present} -gt 0 ]] && CVE_FANOUT_SUMMARY+=" (${present} already existed)"
    [[ ${repaired} -gt 0 ]] && CVE_FANOUT_SUMMARY+=" (${repaired} unfinished repaired)"
  fi
  [[ ${followed} -gt 0 ]] && CVE_FANOUT_SUMMARY+="; ${followed} branch(es) follow another branch and get no issue"
  return 0
}

# cve_rollup_body REPO PARENT_NUMBER VULN_ID → markdown table on stdout.
# Returns 1 when the parent has no branch issues for this id.
# A child's branch is read back from its host-written title and re-checked
# against the branch pattern; any other title is ignored.
cve_rollup_body() {
  local repo="$1" parent="$2" id="$3" subs rows b
  subs=$(gh api "repos/${repo}/issues/${parent}/sub_issues?per_page=100") || return 1
  rows=$(jq -r --arg id "${id}" '
    .[]
    | select((.title // "") | test("^" + $id + ": [A-Za-z0-9][A-Za-z0-9._/-]{0,99}$"))
    | (.title | sub("^[^ ]+ "; "")) as $branch
    | ([(.labels // [])[].name | select(startswith("cve:")) | sub("^cve:"; "")] | first // "pending") as $verdict
    | "| `\($branch)` | #\(.number) | \($verdict) | \(.state) |"' <<<"${subs}") || return 1
  [[ -n "${rows}" ]] || return 1
  printf '### %s across maintained branches\n\n' "${id}"
  printf '| Branch | Issue | Verdict | Issue state |\n|---|---|---|---|\n%s\n' "${rows}"
  while IFS= read -r b; do
    [[ -z "${b}" ]] && continue
    printf '| `%s` | n/a | follows another branch | no separate change |\n' "${b}"
  done < <(cve_branch_list "${CVE_BRANCHES_FOLLOW:-}")
  printf '\n<sub>Rebuilt from the branch issues each time one is assessed. A fix on one branch says nothing about another.</sub>\n'
}

# cve_parent_of REPO ISSUE_NUMBER → parent issue number, or nothing.
cve_parent_of() {
  local n
  n=$(gh api "repos/$1/issues/$2/parent" --jq '.number' 2>/dev/null) || return 0
  [[ "${n}" =~ ^[0-9]+$ ]] && printf '%s' "${n}"
  return 0
}
# END bundled: lib/cve-fanout.lib.sh
# shellcheck source=lib/jira-auth.lib.sh
# (already bundled: lib/jira-auth.lib.sh)
# shellcheck source=lib/cve-receipt.lib.sh
# BEGIN bundled: lib/cve-receipt.lib.sh
# shellcheck shell=bash
# cve-receipt.lib.sh — DRAFT. A machine-readable record of the cve agent's
# verdict, so the code agent's host scripts can check it before and after
# coding instead of trusting a label or a prompt.
#
# post-cve writes it; pre-code-cve and post-code-cve read it.
#   GitHub: a hidden marker inside the sticky verdict comment
#           <!-- fullsend-cve-receipt:v1 <base64 JSON> -->
#           Only a comment authored by a bot account is accepted.
#   Jira:   the issue property `fullsend.cve.receipt`.
#
# Trust: whoever can edit the bot's comment (repository write access) or the
# issue property (Jira edit permission) can change a receipt. That is the same
# trust the `ready-to-code` label already carries. The receipt is therefore
# never used to widen anything: it can only stop a run, or narrow what a run
# may change. Every field is shape-checked on read.
#
# Receipt: {"v":1, "id", "repository", "ref", "commit", "status",
#           "plan_state", "option", "change_paths": [...]}

[[ -n "${CVE_RECEIPT_SH_LOADED:-}" ]] && return 0
CVE_RECEIPT_SH_LOADED=1

CVE_RECEIPT_PROPERTY="fullsend.cve.receipt"

# cve_receipt_build FINDING_JSON RESULT_JSON → receipt JSON on stdout
cve_receipt_build() {
  jq -n --slurpfile f "$1" --slurpfile r "$2" '{
    v: 1,
    id: $f[0].vulnerability.id,
    repository: $f[0].target.repository,
    ref: $f[0].target.ref,
    commit: $f[0].target.commit,
    status: $r[0].status,
    plan_state: ($r[0].remediation.plan_state // ""),
    option: ($r[0].remediation.option // ""),
    change_paths: ($r[0].remediation.change_paths // [])
  }'
}

# cve_receipt_valid → reads receipt JSON on stdin; prints it compact when the
# shape is acceptable, fails otherwise.
cve_receipt_valid() {
  jq -ce 'select(
    type == "object" and .v == 1
    and (.id | type == "string" and test("^(CVE-[0-9]{4}-[0-9]{4,}|GHSA(-[23456789cfghjmpqrvwx]{4}){3})$"))
    and (.repository | type == "string" and test("^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$"))
    and (.ref | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$") and (contains("..") | not))
    and (.commit | type == "string" and test("^[0-9a-f]{40}$"))
    and (.status | type == "string") and (.plan_state | type == "string") and (.option | type == "string")
    and (.change_paths | type == "array" and length <= 200)
    and all(.change_paths[]; type == "string" and test("^[A-Za-z0-9._@+-][A-Za-z0-9._/@+-]{0,299}$") and (contains("..") | not))
  )'
}

# cve_receipt_embed RECEIPT_JSON → the hidden comment marker
cve_receipt_embed() {
  printf '<!-- fullsend-cve-receipt:v1 %s -->' "$(printf '%s' "$1" | base64 | tr -d '\n')"
}

# cve_receipt_read_github OWNER/NAME ISSUE_NUMBER → latest valid receipt from a
# bot-authored comment, or nothing.
cve_receipt_read_github() {
  local bodies marker
  bodies=$(gh api --paginate "repos/$1/issues/$2/comments?per_page=100" \
    --jq '.[] | select(.user.type == "Bot") | .body') || return 1
  marker=$(grep -oE '<!-- fullsend-cve-receipt:v1 [A-Za-z0-9+/=]+ -->' <<<"${bodies}" | tail -n 1) || true
  [[ -n "${marker}" ]] || return 0
  marker="${marker#<!-- fullsend-cve-receipt:v1 }"
  printf '%s' "${marker% -->}" | base64 -d 2>/dev/null | cve_receipt_valid || true
}

# cve_jira_api_base → where Jira REST calls go: JIRA_API_URL (the API gateway
# fullsend sets for a Jira-sourced run) when set, else the site URL. The
# credentials are sent there, so anything but https is refused.
cve_jira_api_base() {
  local base="${JIRA_API_URL:-${JIRA_BASE_URL:-}}"
  while [[ "${base}" == */ ]]; do base="${base%/}"; done
  [[ "${base}" == https://* ]] || { echo "ERROR: the Jira API URL must start with https://" >&2; return 1; }
  printf '%s\n' "${base}"
}

# cve_receipt_read_jira KEY → valid receipt from the issue property, or nothing.
cve_receipt_read_jira() {
  local raw base
  base=$(cve_jira_api_base) || return 1
  raw=$(jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" -sS -m 30 \
    "${base}/rest/api/2/issue/$1/properties/${CVE_RECEIPT_PROPERTY}") || return 1
  jq -c '.value // empty' <<<"${raw}" 2>/dev/null | cve_receipt_valid || true
}

# cve_receipt_write_jira KEY RECEIPT_JSON
cve_receipt_write_jira() {
  local base
  base=$(cve_jira_api_base) || return 1
  jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" -fsS -m 30 -X PUT \
    -H 'Content-Type: application/json' --data "$2" \
    "${base}/rest/api/2/issue/$1/properties/${CVE_RECEIPT_PROPERTY}" >/dev/null
}

# cve_receipt_staging_dir → where pre-code-cve leaves the admitted receipt for
# post-code-cve.
cve_receipt_staging_dir() {
  printf '%s/fullsend-cve-code' "${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
}
# END bundled: lib/cve-receipt.lib.sh
[[ "${CVE_BRANCHES_FOLLOW:-}" == "none" ]] && CVE_BRANCHES_FOLLOW=""

# Rebuild the parent's table. Never fails the run: the verdict on this work
# item is already published (or printed) when this is called.
cve_rollup_update() {  # cve_rollup_update REPO ISSUE_NUMBER VULN_ID [DRY]
  local repo="$1" num="$2" id="$3" dry="${4:-}" parent table
  parent=$(cve_parent_of "${repo}" "${num}")
  [[ -n "${parent}" ]] || return 0
  table=$(cve_rollup_body "${repo}" "${parent}" "${id}") || { echo "::warning::cve: could not rebuild the branch table on #${parent}"; return 0; }
  if [[ -n "${dry}" ]]; then
    echo "cve (dry run): would update the branch table marked fullsend-cve-rollup:${id} on #${parent}"
    printf -- '--- branch table ---\n%s\n' "${table}"
    return 0
  fi
  printf '%s' "${table}" | fullsend post-comment --repo "${repo}" --number "${parent}" \
    --marker "fullsend-cve-rollup:${id}" --token "${GH_TOKEN}" --result - \
    || echo "::warning::cve: could not post the branch table on #${parent}"
}

# The validated iteration when the CLI names it; otherwise the last one.
RESULT=""
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  RESULT="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
else
  for dir in iteration-*/output; do
    [[ -f "${dir}/agent-result.json" ]] && RESULT="${dir}/agent-result.json"
  done
fi
[[ -n "${RESULT}" && -f "${RESULT}" ]] || { echo "::error::cve: agent-result.json not found"; exit 1; }

# Binding: the verdict must be about the finding and commit pre-cve staged.
FINDING="${RUNNER_TEMP}/fullsend-cve-stage/cve-finding.json"
[[ -f "${FINDING}" ]] || { echo "::error::cve: staged finding missing at ${FINDING}"; exit 1; }
want_commit=$(jq -r .target.commit "${FINDING}")
want_ref=$(jq -r .target.ref "${FINDING}")
ticket_note=$(jq -r 'if .staged then "ticket text read" else "ticket text not read (" + (.reason // "not staged") + ")" end' \
  "${RUNNER_TEMP}/fullsend-cve-stage/cve-ticket.json" 2>/dev/null || echo "ticket text not read")
want_id=$(jq -r .vulnerability.id "${FINDING}")
got_commit=$(jq -r .bound_commit "${RESULT}")
got_id=$(jq -r .finding_ref "${RESULT}")
if [[ "${got_commit}" != "${want_commit}" || "${got_id}" != "${want_id}" ]]; then
  echo "::error::cve: result is bound to ${got_id}@${got_commit:0:12}, expected ${want_id}@${want_commit:0:12}; discarding"
  exit 1
fi

# pre-cve moves the runner's checkout to the assessed branch for the sandbox.
# Put it back before anything is published: the fullsend CLI reads the Jira
# site from .fullsend/config.yaml in that checkout, and a release branch may
# not have the file.
RESTORE_FILE="${RUNNER_TEMP}/fullsend-cve-stage/restore-commit"
if [[ -f "${RESTORE_FILE}" ]]; then
  restore_commit=$(head -c 64 "${RESTORE_FILE}" | tr -d '[:space:]')
  [[ "${restore_commit}" =~ ^[0-9a-f]{40,64}$ ]] \
    || { echo "::error::cve: the recorded checkout to restore is not a commit id"; exit 1; }
  git -C "${TARGET_REPO_DIR:?}" checkout -q --detach "${restore_commit}" \
    || { echo "::error::cve: could not restore the runner's checkout to ${restore_commit:0:12}; nothing was published"; exit 1; }
fi

status=$(jq -r .status "${RESULT}")
case "${status}" in
  known_affected) label="cve:affected" ;;
  known_not_affected) label="cve:not-affected" ;;
  fixed) label="cve:fixed" ;;
  under_investigation) label="cve:investigating" ;;
  *) label="cve:failed" ;;
esac

promote=""
if [[ "${CVE_AUTO_CODE:-off}" == "on" && "${status}" == "known_affected" ]] \
   && jq -e '.remediation.plan_state == "ready" and .remediation.option != "rebuild"' "${RESULT}" >/dev/null; then
  promote="yes"
fi

body="$(jq -r .comment "${RESULT}")

<sub>cve agent · ${want_id} · branch \`${want_ref}\` · \`${want_commit:0:12}\` · status \`${status}\`$(jq -r 'if .justification then " · " + .justification else "" end' "${RESULT}") · ${ticket_note} · proposed for human review, not a published VEX statement</sub>"

# The receipt is what the code agent's host scripts check before and after
# coding (pre-code-cve, post-code-cve). On GitHub it rides in the comment.
RECEIPT=$(cve_receipt_build "${FINDING}" "${RESULT}" | cve_receipt_valid) \
  || { echo "::error::cve: could not build a valid receipt from the verdict"; exit 1; }
if [[ "${FULLSEND_TRACKER}" != "jira" ]]; then
  body+="
$(cve_receipt_embed "${RECEIPT}")"
fi

if [[ -n "${DRY_RUN}" ]]; then
  echo "cve (dry run): would record the receipt ${RECEIPT}"
  echo "cve (dry run): would post a sticky comment marked fullsend-cve:${want_id} on ${ISSUE_URL}"
  echo "cve (dry run): would set label ${label}${promote:+ and ready-to-code}"
  printf -- '--- comment body ---\n%s\n' "${body}"
  if [[ "${FULLSEND_TRACKER}" == "github" && "${ISSUE_URL}" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/issues/([0-9]+)$ ]]; then
    cve_rollup_update "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${want_id}" dry
  fi
  exit 0
fi

tracker_validate_issue_url
tracker_parse_issue_url
tracker_post_sticky_comment "${body}" "fullsend-cve:${want_id}"
if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
  jira_key="$(basename "${ISSUE_URL}")"
  [[ "${jira_key}" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || { echo "::error::cve: cannot derive the Jira key for the receipt"; exit 1; }
  cve_receipt_write_jira "${jira_key}" "${RECEIPT}" \
    || { echo "::error::cve: the verdict comment was posted but its receipt was not recorded; the code agent will refuse this work item until /fs-cve is run again"; exit 1; }
fi

for l in cve:affected cve:not-affected cve:fixed cve:investigating cve:failed; do
  [[ "${l}" == "${label}" ]] || tracker_remove_label "${l}" 2>/dev/null || true
done
tracker_add_label "${label}"

if [[ -n "${promote}" ]]; then
  tracker_add_label "ready-to-code"
  echo "::notice::cve: promoted to ready-to-code"
fi

if [[ "${FULLSEND_TRACKER}" == "github" ]]; then
  cve_rollup_update "${REPO}" "${ISSUE_NUMBER}" "${want_id}"
fi
