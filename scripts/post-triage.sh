#!/usr/bin/env bash
# GENERATED from post-triage.src.sh — DO NOT EDIT. Run: make script-build
# post-triage.sh — Parse triage agent JSON output and perform mutations.
#
# Runs on the host after sandbox cleanup. Working directory is the fullsend
# run output directory (e.g., /tmp/fullsend/agent-triage-<id>/iteration-1/).
#
# Required env vars:
#   ISSUE_URL        — HTML URL of the issue
#   FULLSEND_TRACKER — "github", "gitlab", or "jira" (falls back to FULLSEND_FORGE)
#
# Jira-sourced runs: when FULLSEND_WORK_ITEM_SOURCE is "jira", results are
# written to the Jira issue at FULLSEND_WORK_ITEM_URL (exported by
# `fullsend run`), and FULLSEND_WORK_ITEM_KEY must match that URL.
#
# The agent writes its decision to output/agent-result.json (relative to
# the iteration directory). This script finds the most recent iteration's output.
#
# IMPORTANT: Label mutations use the labels API directly instead of issue edit
# commands. On GitHub, gh issue edit uses PATCH /issues/{number} which fires
# issues.edited, re-triggering the triage dispatch in the shim workflow.
# The labels API (POST/DELETE /issues/{number}/labels) only fires
# issues.labeled/issues.unlabeled, avoiding the re-triage loop.

set -euo pipefail

# Route Jira-sourced runs to the originating Jira issue. Refuse to run when an
# explicit tracker or ISSUE_URL points elsewhere, so results never land on a
# different work item.
if [[ "${FULLSEND_WORK_ITEM_SOURCE:-}" == "jira" ]]; then
  if [[ -n "${FULLSEND_TRACKER:-}" && "${FULLSEND_TRACKER}" != "jira" ]]; then
    echo "ERROR: FULLSEND_WORK_ITEM_SOURCE is jira but FULLSEND_TRACKER selects a different tracker" >&2
    exit 1
  fi
  FULLSEND_TRACKER="jira"
  if [[ -z "${FULLSEND_WORK_ITEM_URL:-}" || -z "${FULLSEND_WORK_ITEM_KEY:-}" ]]; then
    echo "ERROR: FULLSEND_WORK_ITEM_URL and FULLSEND_WORK_ITEM_KEY are required for a Jira-sourced run" >&2
    exit 1
  fi
  if [[ -n "${ISSUE_URL:-}" && "${ISSUE_URL}" != "${FULLSEND_WORK_ITEM_URL}" ]]; then
    echo "ERROR: ISSUE_URL does not match FULLSEND_WORK_ITEM_URL for a Jira-sourced run" >&2
    exit 1
  fi
  ISSUE_URL="${FULLSEND_WORK_ITEM_URL}"
fi

: "${ISSUE_URL:?ISSUE_URL must be set}"
FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"
: "${FULLSEND_TRACKER:?FULLSEND_TRACKER must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
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

# Prints the GitHub web origin the run executes against, without a trailing
# slash: GITHUB_SERVER_URL (set by GitHub Actions) or https://github.com.
_github_triage_server_url() {
  local server="${GITHUB_SERVER_URL:-https://github.com}"
  printf '%s\n' "${server%/}"
}

tracker_validate_issue_url() {
  local server
  server=$(_github_triage_server_url)
  if [[ ! "${server}" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
    echo "ERROR: GITHUB_SERVER_URL is not an HTTPS origin (https://host[:port]): ${server}" >&2
    return 1
  fi
  # Literal prefix match (including the trailing slash) so look-alike hosts
  # that merely start with the configured host are rejected.
  local path="${ISSUE_URL#"${server}/"}"
  if [[ "${path}" == "${ISSUE_URL}" ]] \
      || [[ ! "${path}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected pattern: ${ISSUE_URL}" >&2
    return 1
  fi
}

tracker_parse_issue_url() {
  local server path
  server=$(_github_triage_server_url)
  path="${ISSUE_URL#"${server}/"}"
  REPO="${path%%/issues/*}"
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
#                     FULLSEND_JIRA_TOKEN to it). Or, instead of it:
#   FULLSEND_JIRA_CLIENT_ID, FULLSEND_JIRA_CLIENT_SECRET
#                   — service-account OAuth 2.0 client credentials. REST
#                     calls then use an access token minted on the runner
#                     and need JIRA_API_URL. Setting both modes fails.
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
#                     to JIRA_BASE_URL when unset (older fullsend releases),
#                     except with client credentials, which require it.
#                     Browse links always use JIRA_BASE_URL.
#
# The `fullsend issues` CLI reads its credentials from FULLSEND_JIRA_TOKEN
# and, for a bot user, FULLSEND_JIRA_EMAIL, and its Jira site and API
# gateway from tracker.jira in --fullsend-dir. jira_auth_fullsend passes
# the same token and email to it, or the client credentials, so one set of
# credentials covers both the raw REST calls in this file and the
# `fullsend` shell-outs below.
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
jira_auth_select "${JIRA_TOKEN:-}" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET || exit 1
if [[ "${JIRA_AUTH_MODE}" == "none" ]]; then
  echo "ERROR: JIRA_TOKEN must be set, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
  exit 1
fi
# JIRA_API_URL is optional, but the credentials are sent to it, so refuse
# anything that is not https.
if [[ -n "${JIRA_API_URL:-}" && "${JIRA_API_URL}" != https://* ]]; then
  echo "ERROR: JIRA_API_URL must start with https://" >&2
  exit 1
fi
jira_auth_require_api_url || exit 1
# Client credentials: mint the access token here, in the script's own
# shell, so later REST calls reuse it. A failure is reported here and each
# REST call then fails on its own, keeping the caller's fail-open or
# fail-closed handling.
jira_auth_mint || true

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

  jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
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
  raw=$(jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${api_base}/rest/api/3${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "Jira API error: curl failed — $(grep -v '^::add-mask::' "${err_file}")" >&2
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
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${REPO}" --number "${JIRA_ISSUE_NUM}" \
    --marker "${marker}" --result -
}

# _jira_own_marked_comments MARKER — print, as a JSON array, every comment
# on the issue (all pages) that the posting account (GET /myself) wrote
# with the comment property fullsend.sticky-marker = {"marker": MARKER},
# each with an "_updated" sort key ([UTC seconds, nanoseconds, numeric
# id]). `fullsend issues post-comment` sets that
# property on the comment it posts: in fullsend v0.56.1-rc.1 (pinned in
# go.mod) and v0.56.1 it edits that comment in place, and on
# fullsend-ai/fullsend#9399 (head 5150c261) every run creates a new comment
# with it (internal/tracker/jira_client.go, CreateCommentWithMarker;
# internal/cli/issues.go, postJiraStickyComment). Jira writes times as
# "2026-11-17T10:00:00.000+0100"; RFC 3339 "Z" and "+01:00" forms, with or
# without fractional seconds, are accepted too (fullsend's
# jiraTimestampFormats). A time that does not parse is an error.
_jira_own_marked_comments() {
  local marker="$1"
  local self
  self=$(_jira_api_with_status GET "/myself" | jq -r '.accountId // empty') || return 1
  if [[ -z "${self}" ]]; then
    echo "ERROR: GET /myself returned no accountId" >&2
    return 1
  fi
  # Pages are collected in a file, never passed as arguments: a long
  # issue's comments would overflow the argument size limit.
  # Paging stops on an empty page, at "total" when the page gives one, and
  # otherwise on a page shorter than its maxResults. More than 100 pages
  # fails rather than reading part of the listing.
  local pages page count total page_size start_at=0 n_pages=0
  pages=$(mktemp) || return 1
  while :; do
    n_pages=$((n_pages + 1))
    if [[ ${n_pages} -gt 100 ]]; then
      echo "ERROR: the comment listing has more than 100 pages" >&2
      rm -f "${pages}"
      return 1
    fi
    if ! page=$(_jira_api_with_status GET "/issue/${ISSUE_NUMBER}/comment?expand=properties&orderBy=-created&maxResults=100&startAt=${start_at}") \
      || ! printf '%s\n' "${page}" >> "${pages}" \
      || ! count=$(jq -r '.comments // [] | length' <<<"${page}") \
      || ! total=$(jq -r '.total // "" | tostring' <<<"${page}") \
      || ! page_size=$(jq -r '.maxResults // 100' <<<"${page}"); then
      rm -f "${pages}"
      return 1
    fi
    start_at=$((start_at + count))
    if [[ ${count} -eq 0 ]]; then
      break
    elif [[ "${total}" =~ ^[0-9]+$ ]]; then
      [[ ${start_at} -lt ${total} ]] || break
    elif [[ ${count} -lt ${page_size} ]]; then
      break
    fi
  done
  jq -cs --arg self "${self}" --arg marker "${marker}" '
    def utc_key:
      . as $t
      | (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<f>[0-9]{1,9}))?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")
         // error("unparsable Jira timestamp: \($t)"))
      | [ ((.d + "Z") | fromdateiso8601)
          - (if .z == "Z" then 0
             else (if .s == "+" then 1 else -1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60) end),
          (((.f // "") + "000000000")[0:9] | tonumber) ];
    [ .[] | .comments // [] | .[] | select(.author.accountId == $self)
      | select(any(.properties[]?; .key == "fullsend.sticky-marker" and (.value.marker? == $marker)))
      | (.id | tostring | tonumber? // 0) as $n
      | . + {_updated: (((.updated // .created // "") | utc_key) + [$n])} ]
  ' "${pages}" || { rm -f "${pages}"; return 1; }
  rm -f "${pages}"
}

# tracker_store_triage_state STATE_JSON MARKER — after the post, store the
# triage state on the comment just posted with MARKER, as its entity
# property fullsend.triage-state (ADF has no hidden text). `fullsend issues
# post-comment` prints no comment id, so the comment is the own one with
# MARKER updated last (an edit in place before fullsend-ai/fullsend#9399, a
# new comment after it); a tie goes to the highest comment id. A run with
# no state sets nothing. A time that does not parse, a listing that fails,
# or no matching comment fails the run, like every other Jira write.
tracker_store_triage_state() {
  local state="$1"
  local marker="$2"
  _jira_require_vars || return 1
  [[ -n "${state}" ]] || return 0
  local comments comment_id
  comments=$(_jira_own_marked_comments "${marker}") || {
    echo "ERROR: cannot store the triage state: the comment listing or a timestamp in it could not be read" >&2
    return 1
  }
  comment_id=$(jq -r 'max_by(._updated) | .id // empty' <<<"${comments}") || return 1
  if [[ -z "${comment_id}" ]]; then
    echo "ERROR: cannot store the triage state: no comment by this account carries ${marker}" >&2
    return 1
  fi
  _jira_api_with_status PUT "/comment/${comment_id}/properties/fullsend.triage-state" \
    --data "${state}" > /dev/null || {
    echo "ERROR: cannot store the triage state on comment ${comment_id}; setting a comment property needs the \"Edit own comments\" project permission" >&2
    return 1
  }
  echo "Stored the triage state on comment ${comment_id}"
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
# shellcheck source=lib/labels.lib.sh
# BEGIN bundled: lib/labels.lib.sh
# labels.lib.sh — Mandatory label management for fullsend agent scripts.
#
# Provides forge_ensure_label() which creates mandatory dispatch labels
# by delegating to forge_create_label(). Non-mandatory labels are silently
# skipped (no-op).

# shellcheck shell=bash

[[ -n "${LABELS_SH_LOADED:-}" ]] && return 0
LABELS_SH_LOADED=1

MANDATORY_LABELS=("ready-for-review" "ready-to-code" "ready-for-triage")

_labels_mandatory_defaults() {
  printf '%s\t%s\t%s\n' \
    "ready-for-review" "Triggers review agent dispatch" "0E8A16" \
    "ready-to-code" "Triggers code agent dispatch" "0E8A16" \
    "ready-for-triage" "Triggers triage agent dispatch" "0E8A16"
}

forge_ensure_label() {
  local name="$1"
  local description="${2:-}"
  local color="${3:-}"

  local is_mandatory=false
  local m
  for m in "${MANDATORY_LABELS[@]}"; do
    [[ "${m}" == "${name}" ]] && is_mandatory=true && break
  done
  if [[ "${is_mandatory}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${description}" || -z "${color}" ]]; then
    local line
    line=$(_labels_mandatory_defaults | grep "^${name}	" || true)
    if [[ -n "${line}" ]]; then
      [[ -z "${description}" ]] && description=$(printf '%s' "${line}" | cut -f2)
      [[ -z "${color}" ]] && color=$(printf '%s' "${line}" | cut -f3)
    fi
  fi

  # forge_create_label uses upsert semantics (--force on GitHub, 409-ignore
  # on GitLab).  This intentionally overwrites any admin-customized
  # description/color — mandatory labels are agent-managed.
  forge_create_label "${name}" "${description}" "${color}"
}
# END bundled: lib/labels.lib.sh
# shellcheck source=lib/triage-state.lib.sh
# BEGIN bundled: lib/triage-state.lib.sh
# shellcheck shell=bash
# triage-state.lib.sh — The triage state a re-triage run starts from
# (fullsend-ai/agents#2042).
#
# A sufficient result carries triage_summary.open_causes and
# triage_summary.ruled_out, each a list of {cause, evidence, verified}. The
# post-script lists them in the comment for people and stores them as data
# for the next run: on GitHub and GitLab as a hidden HTML comment at the end
# of the comment body,
#
#   <!-- triage-state-v1:<base64 of {"open_causes":[...],"ruled_out":[...]}> -->
#
# and on Jira, which has no hidden text in ADF, as the comment entity
# property fullsend.triage-state (see jira-triage-ops.lib.sh).
#
# The marker is not in fullsend's "<!-- fullsend:" namespace on purpose:
# `fullsend post-comment` escapes every such marker in the body it is given,
# so only its own marker stays live. Trust in this one comes from the
# comment's author, which the agent checks (agents/triage.md step 2e), and
# from triage_state_neutralize, which escapes any copy the agent wrote.
#
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${TRIAGE_STATE_SH_LOADED:-}" ]] && return 0
TRIAGE_STATE_SH_LOADED=1

# The readable comment cap from agents/triage.md. It applies to everything
# posted except the hidden state marker: the agent's comment, the lists and
# the footers (see triage_state_compose).
TRIAGE_STATE_READABLE_CAP=4000
# Jira caps an entity property value at 32768 bytes of stored JSON. Keep the
# state's UTF-8 bytes under 30000 for room to spare; only multibyte text can
# come near it. TRIAGE_STATE_MAX_BYTES may lower the cap (tests do), never
# raise it.
if [[ "${TRIAGE_STATE_MAX_BYTES:-}" =~ ^[0-9]{1,9}$ ]] && (( 10#${TRIAGE_STATE_MAX_BYTES} <= 30000 )); then
  TRIAGE_STATE_MAX_BYTES=$((10#${TRIAGE_STATE_MAX_BYTES}))
else
  TRIAGE_STATE_MAX_BYTES=30000
fi
# Footers other than "Next steps" (label and component reasons, unapplied
# Jira updates) are cut to this many characters, so "Next steps" always fits.
TRIAGE_STATE_MAX_EXTRA_FOOTER=1000

# The opener of a <summary> whose text reads "Previous run" (any case, with
# whitespace, a hyphen, &nbsp;, a numeric entity or inline tags before or
# between the words), which is what makes a <details> block a history fold
# to step 2e. Agent text has it escaped, so the next run never takes text
# above the state marker for history; the post-script's own <details>
# blocks (prerequisites, split) keep working.
TRIAGE_STATE_FOLD_RE='(?i)<(?=summary\b[^>]*>(?:\s|&nbsp;|&#x?[0-9a-f]+;|<[^>]*>)*previous(?:\s|-|&nbsp;|&#x?[0-9a-f]+;|<[^>]*>)*run)'

# triage_state_json RESULT_FILE — print the state as compact JSON, bounded
# to the schema's limits (whitespace runs folded to one space, strings and
# lists cut, ruled_out keeping its newest entries), or nothing when the
# result has no open cause. Over TRIAGE_STATE_MAX_BYTES it never drops a
# cause: it empties ruled-out evidence, then open evidence, then cuts cause
# text to fewer bytes (whole characters only), and fails, so nothing is
# posted, if the names alone still do not fit.
triage_state_json() {
  jq -c '
    def text($n):
      (if type == "string" then . else "" end)
      | gsub("[\\r\\n\\t]+"; " ") | gsub("^ +| +$"; "")
      | if length > $n then .[0:($n - 1)] + "…" else . end;
    def causes:
      (if type == "array" then . else [] end)
      | map(select(type == "object")
            | {cause: (.cause | text(200)), evidence: (.evidence | text(300)), verified: (.verified == true)}
            | select(.cause != ""));
    (.triage_summary | if type == "object" then . else {} end) as $s
    | {open_causes: ($s.open_causes | causes | .[0:10]),
       ruled_out: ($s.ruled_out | causes | if length > 25 then .[(length - 25):] else . end)}
    | if (.open_causes | length) == 0 then empty else . end
    # Only multibyte text can push the state past the byte cap. jq slices
    # whole characters, so a cut never splits a UTF-8 sequence.
    | def fits: (tojson | utf8bytelength) <= $max_bytes;
      def bytecut($n): until(utf8bytelength <= $n; .[0:(length - 1)]);
      if fits then . else
        .ruled_out |= map(.evidence = "")
        | if fits then . else
            .open_causes |= map(.evidence = "")
            | if fits then . else
                . as $bare
                | ([600, 400, 300, 200, 120, 80, 40]
                   | map(. as $n | $bare | (.open_causes, .ruled_out) |= map(.cause |= bytecut($n)) | select(fits))
                   | first)
                  // error("the triage state does not fit \($max_bytes) bytes even with its cause names cut")
              end
          end
      end
  ' --argjson max_bytes "${TRIAGE_STATE_MAX_BYTES}" "$1"
}

# triage_state_dropped RESULT_FILE STATE_JSON — print how many causes the
# result listed that the state does not keep: entries that are not objects
# or have an empty name, and entries past the 10 open / 25 ruled-out limits.
triage_state_dropped() {
  jq -r --arg s "$2" '
    def n: if type == "array" then length else 0 end;
    (if $s == "" then {} else ($s | fromjson) end) as $state
    | (.triage_summary | if type == "object" then . else {} end) as $ts
    | (($ts.open_causes | n) + ($ts.ruled_out | n))
    - (($state.open_causes | n) + ($state.ruled_out | n))
  ' "$1"
}

# triage_state_compose STATE_JSON AGENT_COMMENT FOOTER — print the readable
# comment that is posted: AGENT_COMMENT, the lists, then FOOTER (the labels,
# components and next-steps sections the post-script appended), within
# TRIAGE_STATE_READABLE_CAP characters. The lists are one line per cause,
# unverified causes marked, "Ruled out" left out when empty. When the whole
# does not fit, the lists are condensed in this order: ruled-out evidence,
# all evidence, the oldest ruled-out lines (counted in one line), then the
# open cause names are cut to 80 characters. If it still does not fit, the
# agent's comment is cut at a line end with a note saying so. Footers other
# than "Next steps" are first held to TRIAGE_STATE_MAX_EXTRA_FOOTER
# characters, so "Next steps" is never cut. The stored state always keeps
# every entry. Every <summary> opener in the agent's comment, the footers
# and the cause lists is escaped: this comment carries the state, and step
# 2e reads a <details> block whose summary reads "Previous run" as history,
# so no spelling of one may appear above the marker. None of this text
# holds a <details> block of the post-script's own.
triage_state_compose() {
  jq -rn --argjson state "$1" --arg agent_in "$2" --arg footer_raw "$3" \
    --argjson cap "${TRIAGE_STATE_READABLE_CAP}" \
    --argjson extra_max "${TRIAGE_STATE_MAX_EXTRA_FOOTER}" '
    def nofold: gsub("(?i)<(?=summary\\b)"; "&lt;");
    ($agent_in | nofold) as $agent | ($footer_raw | nofold) as $footer_in |
    def safe: gsub("<!--"; "&lt;!--") | nofold;
    def clip($n): if length > $n then .[0:($n - 1)] + "…" else . end;
    def line($full; $name_max):
      "- " + (.cause | clip($name_max) | safe)
      + (if .verified then "" else " _(unverified)_" end)
      + (if $full and .evidence != "" then " — " + (.evidence | clip(160) | safe) else "" end);
    def render($o; $r; $full_open; $full_ruled; $hidden; $name_max):
      "**Open causes:**\n" + ($o | map(line($full_open; $name_max)) | join("\n"))
      + (if ($r | length) + $hidden > 0 then
           "\n\n**Ruled out:**\n"
           + ((if $hidden > 0 then ["- \($hidden) earlier ruled-out cause(s) not listed here; the triage state keeps them"] else [] end)
              + ($r | map(line($full_ruled; $name_max))) | join("\n"))
         else "" end);
    def note: "\n\n_(Cut to fit the comment limit; the triage state keeps every cause.)_";
    # The character offset of the last $d, or null. jq before 1.8.0
    # (1.7.1, the default runner image, included) returns byte offsets from
    # index/rindex while slices count characters (jq #3065), so they are
    # not used.
    def last_at($d):
      split($d) as $p
      | if ($p | length) < 2 then null else ($p[:-1] | join($d) | length) end;
    # Cut to $n characters, at a line end when one is in the second half.
    def cutline($n):
      if length <= $n then .
      elif $n <= 0 then ""
      else .[0:($n - 1)] as $c
        | ($c | last_at("\n")) as $i
        | (if ($i // 0) > $n / 2 then $c[0:$i] else $c end) + "…"
      end;
    # The fence a Markdown code block opened in this text and did not close
    # (``` or ~~~, up to three spaces in), or null.
    def open_fence:
      reduce (split("\n")[]) as $l (null;
        if . == null then ([$l | capture("^ {0,3}(?<f>`{3,}|~{3,})")] | .[0].f // null)
        elif (. as $f | $l | test("^ {0,3}" + $f[0:1] + "{" + ($f | length | tostring) + ",}\\s*$")) then null
        else . end);
    # The longest fence-opening run in this text, so a closing fence always
    # has room.
    def fence_room:
      [split("\n")[] | capture("^ {0,3}(?<f>`{3,}|~{3,})") | .f | length] | (max // 0) + 1;
    # Cut to $n characters like cutline, then close a code block the cut
    # left open, so the lists after it render as Markdown.
    def cut_closed($n):
      fence_room as $room
      | cutline($n - $room) as $c
      | ($c | open_fence) as $f
      | if $f == null then $c else $c + "\n" + $f end;
    ("\n\n---\n**Next steps:**") as $ns_head
    | ("\n\n---\n**Not applied in Jira:**") as $na_head
    | ($footer_in | (last_at($ns_head) // length)) as $ns_at
    # The other footers keep "Not applied in Jira" whole where they can, and
    # cut the label and component reasons first.
    | ($footer_in[0:$ns_at]) as $pre
    | ($pre | (last_at($na_head) // length)) as $na_at
    | ($pre[$na_at:] | cutline($extra_max)) as $notice
    | (($pre[0:$na_at] | cutline($extra_max - ($notice | length))) + $notice) as $extra
    | ($extra + $footer_in[$ns_at:]) as $footer
    # The agent comment with a code block it left open closed, so the lists
    # after it render as Markdown even when nothing is cut.
    | ($agent | open_fence) as $agent_fence
    | ((if $agent_fence == null then $agent else $agent + "\n" + $agent_fence end) + "\n\n") as $head
    | ($cap - ($head | length) - ($footer | length)) as $budget
    | $state.open_causes as $o | $state.ruled_out as $r
    | ([ render($o; $r; true; true; 0; 200),
         render($o; $r; true; false; 0; 200),
         render($o; $r; false; false; 0; 200),
         (range(1; ($r | length) + 1) as $k | render($o; $r[$k:]; false; false; $k; 200)),
         render($o; []; false; false; ($r | length); 80) ]
       | (map(select(length <= $budget)) | first) // last) as $lists
    | ($head + $lists + $footer) as $all
    | if ($all | length) <= $cap then $all
      else
        # The lists (at most about 1200 characters) and the bounded footers
        # leave room for the agent comment, so only it is cut.
        ($cap - ($lists | length) - ($footer | length) - 2 - (note | length)) as $keep
        | ($agent | cut_closed($keep)) + note + "\n\n" + $lists + $footer
      end
  '
}

# triage_state_marker STATE_JSON — print the hidden marker for GitHub/GitLab.
triage_state_marker() {
  local encoded
  encoded="$(printf '%s' "$1" | base64 | tr -d '\n')"
  printf '<!-- triage-state-v1:%s -->' "${encoded}"
}

# triage_state_neutralize TEXT — escape every state marker opener in TEXT
# (any case, "<!--" with any number of extra dashes and any whitespace), so
# the only live marker in a posted comment is the one the post-script adds,
# and every "Previous run" fold summary (TRIAGE_STATE_FOLD_RE).
triage_state_neutralize() {
  jq -rn --arg t "$1" --arg fold_re "${TRIAGE_STATE_FOLD_RE}" \
    '$t | gsub("(?i)<(?=!--+\\s*triage-state)"; "&lt;") | gsub($fold_re; "&lt;")'
}
# END bundled: lib/triage-state.lib.sh

# Find the triage result JSON — prefer the validated iteration when set.
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

echo "Reading triage result from: ${RESULT_FILE}"

# Validate JSON is parseable.
if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON" >&2
  exit 1
fi

ACTION=$(jq -r '.action' "${RESULT_FILE}")
COMMENT=$(jq -r '.comment // empty' "${RESULT_FILE}")

tracker_validate_issue_url
tracker_parse_issue_url

if [[ "${FULLSEND_TRACKER}" == "jira" && -n "${FULLSEND_WORK_ITEM_KEY:-}" \
      && "${FULLSEND_WORK_ITEM_KEY}" != "${ISSUE_NUMBER}" ]]; then
  echo "ERROR: FULLSEND_WORK_ITEM_KEY does not match the Jira issue key in ISSUE_URL" >&2
  exit 1
fi

echo "Action: ${ACTION}"
echo "Repo: ${REPO}"
echo "Issue: #${ISSUE_NUMBER}"

# Control labels managed by the triage pipeline. The post script refuses to
# add or remove these via label_actions. pre-triage.sh resets needs-info,
# ready-to-code, duplicate, feature, question, not-planned, completed,
# and pr-open before each run; the action handlers below apply the rest.
# pr-open is also created and applied independently by the code agent's
# pre-check (scripts/pre-code.sh) when it finds a human PR before dispatching.
CONTROL_LABELS=("needs-info" "ready-to-code" "duplicate" "feature" "blocked" "triaged" "question" "bug" "documentation" "not-planned" "completed" "pr-open")

is_control_label() {
  local label="$1"
  for cl in "${CONTROL_LABELS[@]}"; do
    if [[ "${cl}" == "${label}" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Action-specific validation and control labels ---

# The triage state (open and ruled-out causes) of a sufficient result, which
# the next triage run starts from, and the agent's own comment, which the
# cause lists follow. Empty for every other action.
TRIAGE_STATE=""
AGENT_COMMENT=""
TRIAGE_MARKER="<!-- fullsend:triage-agent -->"
# Built before any label, comment or property on the issue is changed, so a
# state that cannot be stored fails the run with the issue untouched.
if [[ "${ACTION}" == "sufficient" ]]; then
  if ! TRIAGE_STATE=$(triage_state_json "${RESULT_FILE}"); then
    echo "::error::the triage state cannot be stored (see above); nothing was posted"
    exit 1
  fi
  TRIAGE_DROPPED=$(triage_state_dropped "${RESULT_FILE}" "${TRIAGE_STATE}") || exit 1
  if [[ -z "${TRIAGE_STATE}" ]]; then
    echo "::warning::the result has no open cause with a name — posting without a triage state"
  elif [[ "${TRIAGE_DROPPED}" -gt 0 ]]; then
    echo "::warning::${TRIAGE_DROPPED} cause(s) in the result were not stored: an empty name, or past the 10 open / 25 ruled-out limits"
  fi
fi

# Deferred label: when set, applied after label_actions so it fires last.
# This prevents the ready-to-code webhook event from being superseded by
# subsequent label events in the dispatch concurrency group (see #1752).
DEFERRED_LABEL=""

# Clear a stale "triaged" label from a prior re-triage before dispatching on
# the new action. Every terminal action below resets its own set of control
# labels, but "triaged" is only ever re-applied (never removed) by the
# handlers themselves, so it must be cleared up front rather than per-branch.
tracker_remove_label "triaged"

# Classification updates the Jira tracker could not apply. Jira users do not
# see workflow annotations, so these are also listed in the Jira comment
# instead of being dropped with only a log warning.
JIRA_UNAPPLIED=""
note_jira_unapplied() {
  [[ "${FULLSEND_TRACKER}" == "jira" ]] || return 0
  JIRA_UNAPPLIED="${JIRA_UNAPPLIED}
- $1"
}

# --- Cross-repo issue creation allowlist ---
# Used by prerequisites and split actions. Read once before the case
# statement so both handlers share the same config and helper.

WORKSPACE="${GITHUB_WORKSPACE:-${CI_PROJECT_DIR:-/tmp}}"
CONFIG_FILE="${WORKSPACE}/config.yaml"
if [[ ! -f "${CONFIG_FILE}" && ! -f "${WORKSPACE}/config.base.yaml" ]]; then
  CONFIG_FILE="${WORKSPACE}/.fullsend/config.yaml"
fi
# A configuration preset (config.base.yaml) sits beside the overlay. As in
# fullsend's layered config, an overlay that sets tracker replaces the base
# tracker as a whole object (an explicit empty target policy included);
# otherwise tracker is inherited from the base. A null or bare `tracker:` in
# the overlay counts as unset (it inherits the base), matching that merge.
BASE_CONFIG_FILE="$(dirname "${CONFIG_FILE}")/config.base.yaml"
ALLOW_TARGETS_KEY="tracker.${FULLSEND_TRACKER}.allowed_targets"

# ALLOWED_SCOPES holds GitHub orgs or GitLab groups (a scope admits every
# repository under it, including GitLab subgroups); ALLOWED_TARGETS holds
# repositories or Jira project keys allowed by exact match.
ALLOWED_SCOPES=""
ALLOWED_TARGETS=""
if [[ -f "${CONFIG_FILE}" || -f "${BASE_CONFIG_FILE}" ]] && ! command -v yq &>/dev/null; then
  echo "::warning::yq not found — cannot read ${ALLOW_TARGETS_KEY} from config; cross-repo issue creation disabled"
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
  if [[ -n "${TRACKER_PROVIDERS}" && "${TRACKER_PROVIDERS}" != "${FULLSEND_TRACKER}" ]]; then
    echo "::warning::tracker mapping selects provider(s) '${TRACKER_PROVIDERS}' but FULLSEND_TRACKER requires only '${FULLSEND_TRACKER}' — no cross-repo targets granted"
  fi
  # Honor targets only when the tracker selects exactly one provider and it
  # is the tracker issues are created in; otherwise nothing is granted.
  ALLOWED_TARGETS_JSON=$(jq -c --arg provider "${FULLSEND_TRACKER}" '
    (if type == "object" then . else {} end) as $t
    | [("github", "gitlab", "jira") | select($t[.] != null)] as $providers
    | if $providers == [$provider] then ($t[$provider].allowed_targets // {}) else {} end
    | if type == "object" then . else {} end
  ' <<<"${TRACKER_JSON}" 2>/dev/null || echo '{}')
  ALLOWED_SCOPES=$(jq -r --arg provider "${FULLSEND_TRACKER}" '
    (if $provider == "github" then .orgs elif $provider == "gitlab" then .groups else null end)
    | if type == "array" then .[] | strings else empty end
  ' <<<"${ALLOWED_TARGETS_JSON}" 2>/dev/null || true)
  ALLOWED_TARGETS=$(jq -r --arg provider "${FULLSEND_TRACKER}" '
    (if $provider == "jira" then .projects else .repos end)
    | if type == "array" then .[] | strings else empty end
  ' <<<"${ALLOWED_TARGETS_JSON}" 2>/dev/null || true)
fi

is_target_allowed() {
  local target_repo="$1"
  local scope

  if [[ "${target_repo}" == "${REPO}" ]]; then
    return 0
  fi

  # Org/group allowlist (a group also covers its subgroups' projects).
  while IFS= read -r scope; do
    if [[ -n "${scope}" && "${target_repo}" == "${scope}/"* ]]; then
      return 0
    fi
  done <<<"${ALLOWED_SCOPES}"

  if [[ -n "${ALLOWED_TARGETS}" ]] && echo "${ALLOWED_TARGETS}" | grep -qFx "${target_repo}"; then
    return 0
  fi

  return 1
}

case "${ACTION}" in
  insufficient)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'insufficient' but no comment provided" >&2
      exit 1
    fi
    tracker_remove_label "blocked"
    tracker_remove_label "pr-open"
    tracker_add_label "needs-info"
    ;;

  duplicate)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'duplicate' but no comment provided" >&2
      exit 1
    fi
    DUPLICATE_OF=$(jq -r '.duplicate_of' "${RESULT_FILE}")
    if [[ "${DUPLICATE_OF}" == "${ISSUE_NUMBER}" ]]; then
      echo "ERROR: issue cannot be a duplicate of itself (#${ISSUE_NUMBER})" >&2
      exit 1
    fi
    tracker_remove_label "blocked"
    tracker_remove_label "pr-open"
    tracker_add_label "duplicate"
    ;;

  prerequisites)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'prerequisites' but no comment provided" >&2
      exit 1
    fi

    # Process create entries: create issues, collect URLs.
    CREATE_COUNT=$(jq '.prerequisites.create // [] | length' "${RESULT_FILE}")
    CREATED_URLS=""
    FAILED_CREATES=""

    for i in $(seq 0 $((CREATE_COUNT - 1))); do
      TARGET_REPO=$(jq -r ".prerequisites.create[${i}].repo" "${RESULT_FILE}")
      ISSUE_TITLE=$(jq -r ".prerequisites.create[${i}].title" "${RESULT_FILE}")
      ISSUE_BODY=$(jq -r ".prerequisites.create[${i}].body" "${RESULT_FILE}")

      if ! is_target_allowed "${TARGET_REPO}"; then
        echo "::warning::Skipping issue creation in '$(_gha_sanitize "${TARGET_REPO}")' — not in ${ALLOW_TARGETS_KEY}"
        FAILED_CREATES="${FAILED_CREATES}
<details>
<summary>Prerequisite: ${TARGET_REPO} — ${ISSUE_TITLE}</summary>

${ISSUE_BODY}

</details>"
        continue
      fi

      echo "Creating prerequisite issue in $(_gha_sanitize "${TARGET_REPO}")..."
      CREATED_URL=$(tracker_create_issue "${TARGET_REPO}" "${ISSUE_TITLE}" "${ISSUE_BODY}") || {
        echo "::warning::Failed to create issue in '$(_gha_sanitize "${TARGET_REPO}")' (see stderr for details)"
        FAILED_CREATES="${FAILED_CREATES}
<details>
<summary>Prerequisite: ${TARGET_REPO} — ${ISSUE_TITLE}</summary>

${ISSUE_BODY}

</details>"
        continue
      }
      echo "Created: ${CREATED_URL}"
      CREATED_URLS="${CREATED_URLS} ${CREATED_URL}"
    done

    # Collect existing URLs.
    EXISTING_COUNT=$(jq '.prerequisites.existing // [] | length' "${RESULT_FILE}")
    EXISTING_URLS=""
    for i in $(seq 0 $((EXISTING_COUNT - 1))); do
      URL=$(jq -r ".prerequisites.existing[${i}].url" "${RESULT_FILE}")
      EXISTING_URLS="${EXISTING_URLS} ${URL}"
    done

    # Merge all blocker URLs for the comment.
    ALL_URLS="${EXISTING_URLS} ${CREATED_URLS}"
    ALL_URLS=$(echo "${ALL_URLS}" | xargs)  # trim whitespace

    if [[ -n "${ALL_URLS}" ]]; then
      BLOCKER_LIST=""
      for url in ${ALL_URLS}; do
        BLOCKER_LIST="${BLOCKER_LIST}
- ${url}"
      done
      COMMENT="${COMMENT}

**Blocked by:**${BLOCKER_LIST}"
    fi

    if [[ -n "${FAILED_CREATES}" ]]; then
      COMMENT="${COMMENT}

**Could not create automatically** (file manually or update \`${ALLOW_TARGETS_KEY}\` in config.yaml):
${FAILED_CREATES}"
    fi

    tracker_remove_label "ready-to-code"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"
    tracker_add_label "blocked"
    ;;

  in-progress)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'in-progress' but no comment provided" >&2
      exit 1
    fi

    # Guard: an in-progress result with no PR to point at is useless — it would
    # apply pr-open and claim a PR addresses the issue without linking one. The
    # schema requires pull_requests here, but re-check rather than trust that
    # validation gated us (the agent is told to emit its best JSON after 3
    # failed validation attempts).
    PR_COUNT=$(jq '.pull_requests // [] | length' "${RESULT_FILE}")
    if [[ "${PR_COUNT}" -eq 0 ]]; then
      echo "ERROR: action is 'in-progress' but no pull_requests provided" >&2
      exit 1
    fi

    # The prompt tells the agent to note separate blockers in comment rather
    # than populating prerequisites alongside pull_requests. Nothing enforces
    # that, so warn when we drop it instead of discarding it silently.
    DROPPED_PREREQS=$(jq '((.prerequisites.existing // []) + (.prerequisites.create // [])) | length' "${RESULT_FILE}")
    if [[ "${DROPPED_PREREQS}" -gt 0 ]]; then
      echo "::warning::Ignoring 'prerequisites' on an 'in-progress' result -- mention separate blockers in 'comment' instead"
    fi

    # Collect PR URLs from pull_requests array. Capture via command
    # substitution rather than process substitution so a jq failure — a
    # pull_requests that passed the count check but is not an array of
    # objects, e.g. a bare string — still trips set -e instead of silently
    # rendering an empty list. -e also rejects a null url.
    PR_URLS=$(jq -er '.pull_requests[].url' "${RESULT_FILE}")
    PR_LIST=""
    while IFS= read -r url; do
      PR_LIST="${PR_LIST}
- ${url}"
    done <<< "${PR_URLS}"

    COMMENT="${COMMENT}

**Addressed by:**${PR_LIST}"

    tracker_remove_label "blocked"
    tracker_remove_label "ready-to-code"
    tracker_remove_label "needs-info"
    tracker_create_label "pr-open" "An open PR already addresses this issue" "D4C5F9"
    tracker_add_label "pr-open"
    ;;

  sufficient)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'sufficient' but no comment provided" >&2
      exit 1
    fi

    # Guard: reject sufficient results that contain information_gaps.
    # If the agent identified open questions, it should have used "insufficient".
    GAP_COUNT=$(jq '.triage_summary.information_gaps // [] | length' "${RESULT_FILE}")
    if [[ "${GAP_COUNT}" -gt 0 ]]; then
      echo "ERROR: action is 'sufficient' but triage_summary contains ${GAP_COUNT} information_gaps — open questions must block triage" >&2
      exit 1
    fi

    # Guard: warn and strip label_actions that contradict triage_summary.category.
    # Maps each category to label names that would be inconsistent (e.g., category
    # "documentation" should not apply an "enhancement" label). See #39.
    # Control labels are excluded — they are already handled by is_control_label().
    if [[ "$(jq 'has("label_actions")' "${RESULT_FILE}")" == "true" ]]; then
      CATEGORY_CHECK=$(jq -r '.triage_summary.category // "unknown"' "${RESULT_FILE}")
      CONTRADICTING_LABELS=""
      case "${CATEGORY_CHECK}" in
        bug)           CONTRADICTING_LABELS="enhancement" ;;
        documentation) CONTRADICTING_LABELS="enhancement" ;;
        performance)   CONTRADICTING_LABELS="enhancement" ;;
        security)      CONTRADICTING_LABELS="enhancement" ;;
      esac
      if [[ -n "${CONTRADICTING_LABELS}" ]]; then
        # Build a jq array of labels to strip.
        JQ_ARRAY="["
        first=true
        for cl in ${CONTRADICTING_LABELS}; do
          ${first} || JQ_ARRAY="${JQ_ARRAY},"
          JQ_ARRAY="${JQ_ARRAY}\"${cl}\""
          first=false
        done
        JQ_ARRAY="${JQ_ARRAY}]"

        # Log which labels are being stripped.
        STRIPPED=$(jq -r --argjson bad "${JQ_ARRAY}" \
          '.label_actions.actions[] | select(.label as $l | $bad | index($l)) | .label' \
          "${RESULT_FILE}")
        for lbl in ${STRIPPED}; do
          echo "::warning::Stripping label '$(_gha_sanitize "${lbl}")' from label_actions — contradicts triage_summary.category '$(_gha_sanitize "${CATEGORY_CHECK}")'"
        done

        # Remove contradicting labels from the actions array.
        if [[ -n "${STRIPPED}" ]]; then
          RESULT_FILE_TMP="${RESULT_FILE}.tmp"
          jq --argjson bad "${JQ_ARRAY}" \
            '.label_actions.actions |= [.[] | select(.label as $l | $bad | index($l) | not)]' \
            "${RESULT_FILE}" > "${RESULT_FILE_TMP}" && mv "${RESULT_FILE_TMP}" "${RESULT_FILE}"

          # If all actions were removed, drop label_actions entirely.
          REMAINING=$(jq '.label_actions.actions | length' "${RESULT_FILE}")
          if [[ "${REMAINING}" -eq 0 ]]; then
            RESULT_FILE_TMP="${RESULT_FILE}.tmp"
            jq 'del(.label_actions)' "${RESULT_FILE}" > "${RESULT_FILE_TMP}" && mv "${RESULT_FILE_TMP}" "${RESULT_FILE}"
          fi
        fi
      fi
    fi

    # The cause lists are rendered under the agent's comment when the
    # comment is posted, and the same state is attached as data
    # (lib/triage-state.lib.sh). A result without open causes, which the
    # schema rejects, is posted without a state, and the next run rebuilds
    # it from the comments.
    AGENT_COMMENT="${COMMENT}"

    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"

    # Low-risk categories (bug, documentation, performance) auto-promote to
    # ready-to-code, which triggers the code agent. Feature work and anything
    # else receives the triaged label and waits for human prioritization
    # (per #561, only feature issues should require human review before coding).
    #
    # TRIAGE_AUTO_CODE (#1754, #1250) controls whether auto-promotion happens:
    #   on / always (default) — auto-promote categories listed in
    #                           TRIAGE_AUTO_CODE_CATEGORIES
    #   off / never           — never auto-promote; always apply triaged
    #   discretionary         — promote only when the agent sets
    #                           triage_summary.promote_to_ready_to_code=true
    #                           AND the category is in TRIAGE_AUTO_CODE_CATEGORIES
    #
    # on and off remain supported aliases for always and never. The agent's
    # promote_to_ready_to_code field is consulted only in discretionary mode;
    # legacy modes ignore its presence or absence.
    #
    # TRIAGE_AUTO_CODE_CATEGORIES is a comma-separated category list with no
    # default baked into this script -- harness/triage.yaml and docs/triage.md
    # own the "bug,documentation,performance" default. An absent or unset
    # TRIAGE_AUTO_CODE_CATEGORIES means no categories auto-promote.
    #
    # Workflow-change guard (#325): if triage detected that the fix requires
    # modifying workflow files (.github/workflows/, .fullsend/.github/workflows/,
    # or shim workflows), skip ready-to-code regardless of category. The code
    # agent cannot modify workflow files under current permissions.
    REQUIRES_WORKFLOW=$(jq -r '.triage_summary.requires_workflow_changes // false' "${RESULT_FILE}")
    CATEGORY=$(jq -r '.triage_summary.category // "unknown"' "${RESULT_FILE}")
    echo "Category: ${CATEGORY}"
    # jq's // treats JSON false as missing, so omitted and false both become
    # the string "false" — the intended withhold default for discretionary mode.
    PROMOTE=$(jq -r '.triage_summary.promote_to_ready_to_code // false' "${RESULT_FILE}")

    AUTO_CODE="${TRIAGE_AUTO_CODE:-on}"
    AUTO_CODE="$(printf '%s' "${AUTO_CODE}" | tr '[:upper:]' '[:lower:]')"

    # Check whether CATEGORY appears in the comma-separated TRIAGE_AUTO_CODE_CATEGORIES list.
    category_in_auto_code_list() {
      local categories="${TRIAGE_AUTO_CODE_CATEGORIES:-}"
      categories="${categories//[[:space:]]/}"
      categories="$(printf '%s' "${categories}" | tr '[:upper:]' '[:lower:]')"
      echo ",${categories}," | grep -qF ",${CATEGORY},"
    }

    # Determine whether this category should auto-promote to ready-to-code.
    auto_code_allowed() {
      case "${AUTO_CODE}" in
        off|never) return 1 ;;
        on|always) category_in_auto_code_list ;;
        discretionary)
          if ! category_in_auto_code_list; then
            return 1
          fi
          [[ "${PROMOTE}" == "true" ]]
          ;;
        *)
          echo "::warning::Unrecognized TRIAGE_AUTO_CODE value '$(_gha_sanitize "${AUTO_CODE}")' — falling back to 'on'"
          category_in_auto_code_list
          ;;
      esac
    }

    # Evaluate once — auto_code_allowed() can emit a ::warning:: for
    # unrecognized TRIAGE_AUTO_CODE values, and calling it repeatedly below
    # would duplicate that annotation in the Actions UI.
    if auto_code_allowed; then
      AUTO_CODE_ALLOWED=true
    else
      AUTO_CODE_ALLOWED=false
    fi

    # Workflow-change guard: if triage detected workflow file changes, always
    # log the (#325) warning for operational visibility. Only block auto-
    # promotion (apply triaged early) when the category would otherwise
    # auto-promote to ready-to-code.
    WORKFLOW_BLOCKED=false
    if [[ "${REQUIRES_WORKFLOW}" == "true" ]]; then
      echo "::warning::Triage detected workflow file changes required (#325)"
      if [[ "${AUTO_CODE_ALLOWED}" == "true" ]]; then
        echo "Applying triaged label (workflow changes required)..."
        tracker_add_label "triaged"
        WORKFLOW_BLOCKED=true
      fi
    fi
    # Clear stale category labels from a prior triage run so a re-categorized
    # issue never carries two conflicting category labels (#1725). These are
    # control labels, so label_actions cannot remove them. Skip the current
    # category's own label to avoid remove/re-add churn.
    for category_label in bug documentation feature; do
      if [[ "${category_label}" != "${CATEGORY}" ]]; then
        tracker_remove_label "${category_label}"
      fi
    done
    case "${CATEGORY}" in
      bug)
        echo "Applying bug label..."
        tracker_add_label "bug"
        if [[ "${WORKFLOW_BLOCKED}" != "true" ]] && [[ "${AUTO_CODE_ALLOWED}" == "true" ]]; then
          echo "Deferring ready-to-code label (${CATEGORY}) until after label_actions..."
          DEFERRED_LABEL="ready-to-code"
        elif [[ "${WORKFLOW_BLOCKED}" != "true" ]]; then
          echo "Applying triaged label (auto-code disabled for ${CATEGORY})..."
          tracker_add_label "triaged"
        fi
        ;;
      documentation)
        echo "Applying documentation label..."
        tracker_add_label "documentation"
        if [[ "${WORKFLOW_BLOCKED}" != "true" ]] && [[ "${AUTO_CODE_ALLOWED}" == "true" ]]; then
          echo "Deferring ready-to-code label (${CATEGORY}) until after label_actions..."
          DEFERRED_LABEL="ready-to-code"
        elif [[ "${WORKFLOW_BLOCKED}" != "true" ]]; then
          echo "Applying triaged label (auto-code disabled for ${CATEGORY})..."
          tracker_add_label "triaged"
        fi
        ;;
      performance)
        if [[ "${WORKFLOW_BLOCKED}" != "true" ]] && [[ "${AUTO_CODE_ALLOWED}" == "true" ]]; then
          echo "Deferring ready-to-code label (${CATEGORY}) until after label_actions..."
          DEFERRED_LABEL="ready-to-code"
        elif [[ "${WORKFLOW_BLOCKED}" != "true" ]]; then
          echo "Applying triaged label (auto-code disabled for ${CATEGORY})..."
          tracker_add_label "triaged"
        fi
        ;;
      feature)
        echo "Applying feature + triaged labels..."
        tracker_add_label "feature"
        tracker_add_label "triaged"
        ;;
      *)
        echo "Applying triaged label (${CATEGORY})..."
        tracker_add_label "triaged"
        ;;
    esac
    ;;

  split)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'split' but no comment provided" >&2
      exit 1
    fi

    SUB_ISSUE_COUNT=$(jq '.sub_issues // [] | length' "${RESULT_FILE}")
    if [[ "${SUB_ISSUE_COUNT}" -lt 2 ]]; then
      echo "ERROR: action is 'split' but fewer than 2 sub-issues provided" >&2
      exit 1
    fi

    CREATED_URLS=""
    FAILED_CREATES=""
    FAILED_DISPATCHES=""
    for i in $(seq 0 $((SUB_ISSUE_COUNT - 1))); do
      SUB_TITLE=$(jq -r ".sub_issues[${i}].title" "${RESULT_FILE}")
      SUB_BODY=$(jq -r ".sub_issues[${i}].body" "${RESULT_FILE}")
      TARGET_REPO=$(jq -r ".sub_issues[${i}].repo // empty" "${RESULT_FILE}")
      TARGET_REPO="${TARGET_REPO:-${REPO}}"

      SAFE_TITLE="${SUB_TITLE//$'\n'/ }"
      SAFE_TITLE="${SAFE_TITLE//::/-}"

      if ! is_target_allowed "${TARGET_REPO}"; then
        echo "::warning::Skipping sub-issue creation in '$(_gha_sanitize "${TARGET_REPO}")' — not in ${ALLOW_TARGETS_KEY}"
        FAILED_CREATES="${FAILED_CREATES}
<details>
<summary>Sub-issue: ${TARGET_REPO} — ${SUB_TITLE}</summary>

${SUB_BODY}

</details>"
        continue
      fi

      echo "Creating sub-issue ${i}: $(_gha_sanitize "${SAFE_TITLE}") (repo: $(_gha_sanitize "${TARGET_REPO}"))..."
      CREATED_URL=$(tracker_create_issue "${TARGET_REPO}" "${SUB_TITLE}" "${SUB_BODY}") || {
        echo "::warning::Failed to create sub-issue '$(_gha_sanitize "${SAFE_TITLE}")' (see stderr for details)"
        FAILED_CREATES="${FAILED_CREATES}
<details>
<summary>Sub-issue: ${TARGET_REPO} — ${SUB_TITLE}</summary>

${SUB_BODY}

</details>"
        continue
      }
      echo "Created: ${CREATED_URL}"
      CREATED_URLS="${CREATED_URLS}
- ${CREATED_URL}"

      # Queue the sub-issue for triage. A dispatch failure must not
      # prevent other sub-issues from being created or dispatched (#1123).
      echo "Dispatching triage for sub-issue: $(_gha_sanitize "${CREATED_URL}")"
      if ! tracker_dispatch_triage "${CREATED_URL}" "${TARGET_REPO}"; then
        FAILED_DISPATCHES="${FAILED_DISPATCHES}
- ${CREATED_URL}"
      fi
    done

    if [[ -z "${CREATED_URLS}" ]] && [[ -n "${FAILED_CREATES}" ]]; then
      echo "ERROR: all sub-issue creations failed — not closing the original issue" >&2
      exit 1
    fi

    if [[ -n "${CREATED_URLS}" ]]; then
      COMMENT="${COMMENT}

**Split into:**${CREATED_URLS}"
    fi

    if [[ -n "${FAILED_CREATES}" ]]; then
      COMMENT="${COMMENT}

**Could not create automatically** (file manually or update \`${ALLOW_TARGETS_KEY}\` in config.yaml):
${FAILED_CREATES}"
    fi

    if [[ -n "${FAILED_DISPATCHES}" ]]; then
      COMMENT="${COMMENT}

**Triage dispatch failed** (run \`/fs-triage\` manually on these issues):
${FAILED_DISPATCHES}"
    fi

    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "ready-to-code"
    tracker_remove_label "pr-open"
    ;;

  question)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'question' but no comment provided" >&2
      exit 1
    fi
    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"
    tracker_add_label "question"
    ;;

  not-planned)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'not-planned' but no comment provided" >&2
      exit 1
    fi
    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"
    tracker_add_label "not-planned"
    ;;

  completed)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'completed' but no comment provided" >&2
      exit 1
    fi
    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"
    tracker_add_label "completed"
    ;;

  *)
    echo "ERROR: unknown action '${ACTION}' — this may be a newer action that post-triage.sh does not handle yet" >&2
    exit 1
    ;;
esac

# --- Process label_actions (applies to all actions) ---

HAS_LABEL_ACTIONS=$(jq 'has("label_actions")' "${RESULT_FILE}")
if [[ "${HAS_LABEL_ACTIONS}" == "true" ]]; then
  LABEL_REASON=$(jq -r '.label_actions.reason' "${RESULT_FILE}")
  LABEL_COUNT=$(jq '.label_actions.actions | length' "${RESULT_FILE}")

  echo "Processing ${LABEL_COUNT} label action(s)..."

  EXISTING_LABELS=$(tracker_list_repo_labels)

  label_exists() {
    local label="$1"
    echo "${EXISTING_LABELS}" | grep -qFx "${label}"
  }

  LABELS_APPLIED=0
  for i in $(seq 0 $((LABEL_COUNT - 1))); do
    LA_ACTION=$(jq -r ".label_actions.actions[${i}].action" "${RESULT_FILE}")
    LA_LABEL=$(jq -r ".label_actions.actions[${i}].label" "${RESULT_FILE}")

    # Validate label name to prevent path injection from untrusted agent output.
    if [[ ! "${LA_LABEL}" =~ ^[a-zA-Z0-9._/:\ +\-]+$ ]]; then
      echo "::warning::Refused label '$(_gha_sanitize "${LA_LABEL}")' -- contains invalid characters"
      continue
    fi

    if is_control_label "${LA_LABEL}"; then
      echo "::warning::Refused to $(_gha_sanitize "${LA_ACTION}") control label '$(_gha_sanitize "${LA_LABEL}")' -- control labels are managed by the triage pipeline"
      continue
    fi

    case "${LA_ACTION}" in
      add)
        if ! label_exists "${LA_LABEL}"; then
          echo "::warning::Skipping label '$(_gha_sanitize "${LA_LABEL}")' -- does not exist in repo (will not auto-create)"
          note_jira_unapplied "Label \`${LA_LABEL}\` was not added: it is not in use on this Jira site, and labels are not auto-created."
          continue
        fi
        echo "Adding label '$(_gha_sanitize "${LA_LABEL}")'..."
        tracker_add_label "${LA_LABEL}"
        LABELS_APPLIED=$((LABELS_APPLIED + 1))
        ;;
      remove)
        echo "Removing label '$(_gha_sanitize "${LA_LABEL}")'..."
        tracker_remove_label "${LA_LABEL}"
        LABELS_APPLIED=$((LABELS_APPLIED + 1))
        ;;
      *)
        echo "::warning::Unknown label action '$(_gha_sanitize "${LA_ACTION}")' for label '$(_gha_sanitize "${LA_LABEL}")'"
        ;;
    esac
  done

  # Append the label reason to the comment only if at least one label was applied.
  if [[ "${LABELS_APPLIED}" -gt 0 ]]; then
    COMMENT="${COMMENT}

---
**Labels:** ${LABEL_REASON}"
  fi
fi

# --- Process component_actions (Jira only) ---

HAS_COMPONENT_ACTIONS=$(jq 'has("component_actions")' "${RESULT_FILE}")
if [[ "${HAS_COMPONENT_ACTIONS}" == "true" ]]; then
  if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
    COMPONENT_REASON=$(jq -r '.component_actions.reason' "${RESULT_FILE}")
    COMPONENT_COUNT=$(jq '.component_actions.actions | length' "${RESULT_FILE}")

    echo "Processing ${COMPONENT_COUNT} component action(s)..."

    # Get current components on the issue. Abort component processing on
    # failure — falling back to "[]" would cause tracker_set_components (a
    # full replacement via PUT) to silently delete pre-existing components.
    if ! CURRENT_COMPONENTS=$(tracker_get_components); then
      echo "::warning::Failed to fetch current components — skipping component mutations to avoid data loss"
      note_jira_unapplied "Component changes were not applied: the current components could not be read, and replacing them blindly could delete existing ones."
    else
      # Build the new component list by applying add/remove actions.
      NEW_COMPONENTS="${CURRENT_COMPONENTS}"
      COMPONENTS_APPLIED=0
      for i in $(seq 0 $((COMPONENT_COUNT - 1))); do
        CA_ACTION=$(jq -r ".component_actions.actions[${i}].action" "${RESULT_FILE}")
        CA_COMPONENT=$(jq -r ".component_actions.actions[${i}].component" "${RESULT_FILE}")

        # Validate component name to prevent injection from untrusted agent output.
        # More permissive than label regex — Jira component names may contain
        # parentheses, ampersands, commas, and apostrophes.
        if [[ ! "${CA_COMPONENT}" =~ ^[a-zA-Z0-9\ _./:+\(\)\&,\'\-]+$ ]]; then
          echo "::warning::Refused component '$(_gha_sanitize "${CA_COMPONENT}")' -- contains invalid characters"
          continue
        fi

        case "${CA_ACTION}" in
          add)
            echo "Adding component '$(_gha_sanitize "${CA_COMPONENT}")'..."
            NEW_COMPONENTS=$(echo "${NEW_COMPONENTS}" | jq --arg c "${CA_COMPONENT}" \
              'if any(. == $c) then . else . + [$c] end')
            COMPONENTS_APPLIED=$((COMPONENTS_APPLIED + 1))
            ;;
          remove)
            echo "Removing component '$(_gha_sanitize "${CA_COMPONENT}")'..."
            NEW_COMPONENTS=$(echo "${NEW_COMPONENTS}" | jq --arg c "${CA_COMPONENT}" \
              '[.[] | select(. != $c)]')
            COMPONENTS_APPLIED=$((COMPONENTS_APPLIED + 1))
            ;;
          *)
            echo "::warning::Unknown component action '$(_gha_sanitize "${CA_ACTION}")' for component '$(_gha_sanitize "${CA_COMPONENT}")'"
            ;;
        esac
      done

      # Apply the updated component list to the issue.
      if [[ "${COMPONENTS_APPLIED}" -gt 0 ]]; then
        COMPONENTS_PAYLOAD=$(echo "${NEW_COMPONENTS}" | jq '[.[] | {name: .}]')
        tracker_set_components "${COMPONENTS_PAYLOAD}"

        COMMENT="${COMMENT}

---
**Components:** ${COMPONENT_REASON}"
      fi
    fi
  else
    echo "Ignoring component_actions — not supported on ${FULLSEND_TRACKER} tracker"
  fi
fi

# --- Apply deferred label (must be last label mutation) ---

if [[ -n "${DEFERRED_LABEL}" ]]; then
  echo "Applying deferred label '${DEFERRED_LABEL}'..."
  # forge_ensure_label creates the label via `gh` against REPO. On Jira, REPO
  # is a project key, not an OWNER/REPO, and Jira has no label registry to
  # create into — any string is already a valid label.
  if [[ "${FULLSEND_TRACKER}" != "jira" ]]; then
    forge_ensure_label "${DEFERRED_LABEL}"
  fi
  tracker_add_label "${DEFERRED_LABEL}"
fi

if [[ -n "${JIRA_UNAPPLIED}" ]]; then
  COMMENT="${COMMENT}

---
**Not applied in Jira:**${JIRA_UNAPPLIED}"
fi

# --- Append action-hints footer (sufficient only) ---

if [[ "${ACTION}" == "sufficient" ]]; then
  COMMENT="${COMMENT}

---
**Next steps:**
- \`/fs-code\` — agent creates a PR to implement this issue
- \`/fs-code <your instruction>\` — agent implements with your specific guidance"
fi

# --- Post comment ---

# Only the post-script's own state marker may be live in a triage comment.
# With a state, everything after the agent's comment is the footers: the
# lists go between the two, and the readable text is held to the cap.
if [[ -n "${TRIAGE_STATE}" ]]; then
  # A literal split by length: the agent's text is never used as a pattern.
  if [[ "${COMMENT:0:${#AGENT_COMMENT}}" != "${AGENT_COMMENT}" ]]; then
    echo "::error::the comment no longer starts with the agent's comment; cannot place the cause lists"
    exit 1
  fi
  FOOTER="${COMMENT:${#AGENT_COMMENT}}"
  NEUTRAL_AGENT=$(triage_state_neutralize "${AGENT_COMMENT}") || exit 1
  NEUTRAL_FOOTER=$(triage_state_neutralize "${FOOTER}") || exit 1
  COMMENT=$(triage_state_compose "${TRIAGE_STATE}" "${NEUTRAL_AGENT}" "${NEUTRAL_FOOTER}") || exit 1
  if [[ "${FULLSEND_TRACKER}" != "jira" ]]; then
    COMMENT="${COMMENT}

$(triage_state_marker "${TRIAGE_STATE}")"
  fi
else
  COMMENT=$(triage_state_neutralize "${COMMENT}") || exit 1
fi

echo "Posting comment..."
if [[ "${ACTION}" == "sufficient" ]]; then
  tracker_post_sticky_comment "${COMMENT}" "${TRIAGE_MARKER}"
  # On Jira the state is a property of the comment, set after it is posted.
  if [[ -n "${TRIAGE_STATE}" && "${FULLSEND_TRACKER}" == "jira" ]]; then
    tracker_store_triage_state "${TRIAGE_STATE}" "${TRIAGE_MARKER}"
  fi
elif [[ "${ACTION}" == "in-progress" ]]; then
  tracker_post_sticky_comment "${COMMENT}" "<!-- fullsend:triage-in-progress -->"
else
  tracker_post_comment "${COMMENT}"
fi

# --- Post-action: close issues ---

if [[ "${ACTION}" == "duplicate" ]]; then
  tracker_close_issue "duplicate"
fi

if [[ "${ACTION}" == "not-planned" ]]; then
  tracker_close_issue "not planned"
fi

if [[ "${ACTION}" == "completed" ]]; then
  tracker_close_issue "completed"
fi

if [[ "${ACTION}" == "split" ]]; then
  tracker_close_issue "completed"
fi

echo "Post-triage complete."
