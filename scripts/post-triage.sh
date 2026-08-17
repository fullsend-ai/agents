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
# The agent writes its decision to output/agent-result.json (relative to
# the iteration directory). This script finds the most recent iteration's output.
#
# IMPORTANT: Label mutations use the labels API directly instead of issue edit
# commands. On GitHub, gh issue edit uses PATCH /issues/{number} which fires
# issues.edited, re-triggering the triage dispatch in the shim workflow.
# The labels API (POST/DELETE /issues/{number}/labels) only fires
# issues.labeled/issues.unlabeled, avoiding the re-triage loop.

set -euo pipefail

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

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@"
}

_gitlab_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file
  err_file=$(mktemp)
  local raw
  raw=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
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
  if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+/-/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitLab pattern: ${ISSUE_URL}" >&2
    return 1
  fi
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  case "${host}" in
    gitlab.com|gitlab.cee.redhat.com) ;;
    *) echo "ERROR: GitLab host '${host}' is not in the allowed host list" >&2; return 1 ;;
  esac
}

tracker_parse_issue_url() {
  # Extract host, project path, and issue IID from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/issues/42
  GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
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
#   JIRA_USER_EMAIL — Jira account email for Basic auth
#   JIRA_TOKEN      — Jira Cloud API token
#
# These are the same env var names the `fullsend issues` CLI commands read
# by default (see `fullsend issues post-comment --help`) — using the same
# names here means one set of credentials covers both the raw REST calls
# in this file and the `fullsend` shell-outs below.
#
# Optional env vars:
#   JIRA_DUPLICATE_TRANSITION   — transition name for the "duplicate" action
#   JIRA_NOT_PLANNED_TRANSITION — transition name for the "not planned" action
#   JIRA_SPLIT_TRANSITION       — transition name for the "split" action
#   JIRA_CREATE_ISSUE_TYPE      — issue type name for cross-project issue
#                                 creation (default: "Task")

[[ -n "${JIRA_TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
JIRA_TRIAGE_OPS_SH_LOADED=1

_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
    --header "Content-Type: application/json" \
    --request "${method}" \
    "${JIRA_BASE_URL}/rest/api/3${endpoint}" \
    "$@"
}

_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file
  err_file=$(mktemp)
  local raw
  raw=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
    --header "Content-Type: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${JIRA_BASE_URL}/rest/api/3${endpoint}" \
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
  JIRA_BASE_URL="https://${host}"
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
  _jira_api PUT "/issue/${ISSUE_NUMBER}" \
    --data "$(jq -cn --arg l "${label}" '{update:{labels:[{remove:$l}]}}')" > /dev/null 2>/dev/null || true
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
  local current_labels
  current_labels=$(_jira_api GET "/issue/${ISSUE_NUMBER}?fields=labels" 2>/dev/null | jq -r '[.fields.labels[]] | join(",")' 2>/dev/null || echo "VERIFY_FAILED")

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

# --- Comments ---

tracker_post_comment() {
  local body="$1"
  # `fullsend issues post-comment` always does marker-based find-and-update;
  # there is no "always create new" mode. A marker unique to this invocation
  # guarantees no prior comment matches it, so this always creates a new
  # comment — matching tracker_post_comment's always-new contract on
  # GitHub/GitLab.
  local marker
  marker="<!-- fullsend:triage-$(date +%s%N) -->"
  printf '%s' "${body}" | fullsend issues post-comment --tracker jira \
    --project "${REPO}" --number "${JIRA_ISSUE_NUM}" \
    --jira-url "${JIRA_BASE_URL}" --jira-email "${JIRA_USER_EMAIL}" --token "${JIRA_TOKEN}" \
    --marker "${marker}" --result -
}

tracker_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  printf '%s' "${body}" | fullsend issues post-comment --tracker jira \
    --project "${REPO}" --number "${JIRA_ISSUE_NUM}" \
    --jira-url "${JIRA_BASE_URL}" --jira-email "${JIRA_USER_EMAIL}" --token "${JIRA_TOKEN}" \
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

tracker_create_issue() {
  local target_project="$1"
  local title="$2"
  local body="$3"
  local issue_type="${JIRA_CREATE_ISSUE_TYPE:-Task}"
  # Jira Cloud REST v3 requires the description as Atlassian Document
  # Format, not plain text/markdown. A single-paragraph doc is sufficient
  # here since prerequisite/sub-issue bodies are plain text.
  local description_adf
  description_adf=$(jq -cn --arg text "${body}" \
    '{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:$text}]}]}')
  local response
  response=$(_jira_api_with_status POST "/issue" \
    --data "$(jq -cn --arg proj "${target_project}" --arg title "${title}" \
      --arg itype "${issue_type}" --argjson desc "${description_adf}" \
      '{fields:{project:{key:$proj},summary:$title,description:$desc,issuetype:{name:$itype}}}')") || {
    echo "Jira API error: failed to create issue in ${target_project}" >&2
    return 1
  }
  local key
  key=$(echo "${response}" | jq -r '.key')
  echo "${JIRA_BASE_URL}/browse/${key}"
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
# without --force, preserving admin customizations. Non-mandatory labels
# are silently skipped (no-op).

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

  local create_args=("${name}" --repo "${REPO_FULL_NAME:-${REPO}}")
  [[ -n "${description}" ]] && create_args+=(--description "${description}")
  [[ -n "${color}" ]] && create_args+=(--color "${color}")

  local err
  if ! err=$(gh label create "${create_args[@]}" 2>&1); then
    case "${err}" in
      *already\ exists*) ;;
      *)
        err="${err//$'\n'/ }"
        err="${err//::/:}"
        err="${err//%0A/}"
        err="${err//%0a/}"
        err="${err//%0D/}"
        err="${err//%0d/}"
        echo "Warning: gh label create ${name}: ${err}" >&2
        ;;
    esac
  fi
}
# END bundled: lib/labels.lib.sh

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

echo "Action: ${ACTION}"
echo "Repo: ${REPO}"
echo "Issue: #${ISSUE_NUMBER}"

# Control labels managed by the triage pipeline. The post script refuses to
# add or remove these via label_actions. pre-triage.sh resets needs-info,
# ready-to-code, duplicate, feature, question, not-planned, and pr-open
# before each run; the action handlers below apply the rest. pr-open is
# also created and applied independently by the code agent's pre-check
# (scripts/pre-code.sh) when it finds a human PR before dispatching.
CONTROL_LABELS=("needs-info" "ready-to-code" "duplicate" "feature" "blocked" "triaged" "question" "bug" "documentation" "not-planned" "pr-open")

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

# Deferred label: when set, applied after label_actions so it fires last.
# This prevents the ready-to-code webhook event from being superseded by
# subsequent label events in the dispatch concurrency group (see #1752).
DEFERRED_LABEL=""

# Clear a stale "triaged" label from a prior re-triage before dispatching on
# the new action. Every terminal action below resets its own set of control
# labels, but "triaged" is only ever re-applied (never removed) by the
# handlers themselves, so it must be cleared up front rather than per-branch.
tracker_remove_label "triaged"

# --- Cross-repo issue creation allowlist ---
# Used by prerequisites and split actions. Read once before the case
# statement so both handlers share the same config and helper.

WORKSPACE="${GITHUB_WORKSPACE:-${CI_PROJECT_DIR:-/tmp}}"
CONFIG_FILE="${WORKSPACE}/config.yaml"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="${WORKSPACE}/.fullsend/config.yaml"
fi

ALLOWED_ORGS=""
ALLOWED_REPOS=""
ALLOWED_JIRA_PROJECTS=""
if [[ -f "${CONFIG_FILE}" ]] && ! command -v yq &>/dev/null; then
  echo "::warning::yq not found — cannot read create_issues.allow_targets from config; cross-repo issue creation disabled"
fi
if [[ -f "${CONFIG_FILE}" ]] && command -v yq &>/dev/null; then
  ALLOWED_ORGS=$(yq -r '.create_issues.allow_targets.orgs // [] | .[]' "${CONFIG_FILE}" 2>/dev/null || true)
  ALLOWED_REPOS=$(yq -r '.create_issues.allow_targets.repos // [] | .[]' "${CONFIG_FILE}" 2>/dev/null || true)
  ALLOWED_JIRA_PROJECTS=$(yq -r '.create_issues.allow_targets.jira_projects // [] | .[]' "${CONFIG_FILE}" 2>/dev/null || true)
fi

is_target_allowed() {
  local target_repo="$1"
  local target_org="${target_repo%%/*}"

  if [[ "${target_repo}" == "${REPO}" ]]; then
    return 0
  fi

  if [[ -n "${ALLOWED_ORGS}" ]] && echo "${ALLOWED_ORGS}" | grep -qFx "${target_org}"; then
    return 0
  fi

  if [[ -n "${ALLOWED_REPOS}" ]] && echo "${ALLOWED_REPOS}" | grep -qFx "${target_repo}"; then
    return 0
  fi

  if [[ -n "${ALLOWED_JIRA_PROJECTS}" ]] && echo "${ALLOWED_JIRA_PROJECTS}" | grep -qFx "${target_repo}"; then
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
        echo "::warning::Skipping issue creation in '$(_gha_sanitize "${TARGET_REPO}")' — not in create_issues.allow_targets"
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

**Could not create automatically** (file manually or update \`create_issues.allow_targets\` in config.yaml):
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

    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"

    # Low-risk categories (bug, documentation, performance) auto-promote to
    # ready-to-code, which triggers the code agent. Feature work and anything
    # else receives the triaged label and waits for human prioritization
    # (per #561, only feature issues should require human review before coding).
    #
    # TRIAGE_AUTO_CODE (#1754) controls whether auto-promotion happens:
    #   on (default) — auto-promote categories listed in TRIAGE_AUTO_CODE_CATEGORIES
    #   off          — never auto-promote; always apply triaged
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
        off) return 1 ;;
        on) category_in_auto_code_list ;;
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
    for i in $(seq 0 $((SUB_ISSUE_COUNT - 1))); do
      SUB_TITLE=$(jq -r ".sub_issues[${i}].title" "${RESULT_FILE}")
      SUB_BODY=$(jq -r ".sub_issues[${i}].body" "${RESULT_FILE}")
      TARGET_REPO=$(jq -r ".sub_issues[${i}].repo // empty" "${RESULT_FILE}")
      TARGET_REPO="${TARGET_REPO:-${REPO}}"

      SAFE_TITLE="${SUB_TITLE//$'\n'/ }"
      SAFE_TITLE="${SAFE_TITLE//::/-}"

      if ! is_target_allowed "${TARGET_REPO}"; then
        echo "::warning::Skipping sub-issue creation in '$(_gha_sanitize "${TARGET_REPO}")' — not in create_issues.allow_targets"
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

**Could not create automatically** (file manually or update \`create_issues.allow_targets\` in config.yaml):
${FAILED_CREATES}"
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

# --- Apply deferred label (must be last label mutation) ---

if [[ -n "${DEFERRED_LABEL}" ]]; then
  echo "Applying deferred label '${DEFERRED_LABEL}'..."
  forge_ensure_label "${DEFERRED_LABEL}"
  forge_add_label "${DEFERRED_LABEL}"
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

echo "Posting comment..."
if [[ "${ACTION}" == "sufficient" ]]; then
  tracker_post_sticky_comment "${COMMENT}" "<!-- fullsend:triage-agent -->"
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

if [[ "${ACTION}" == "split" ]]; then
  tracker_close_issue "completed"
fi

echo "Post-triage complete."
