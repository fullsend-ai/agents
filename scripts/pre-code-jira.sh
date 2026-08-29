#!/usr/bin/env bash
# GENERATED from pre-code-jira.src.sh — DO NOT EDIT. Run: make script-build
# Pre-script for Jira-sourced code agent runs.
#
# Fetches the Jira issue through `fullsend issues get --tracker jira`,
# validates the response against the normalized event, and writes the
# issue context to the path that host_files copies into the sandbox.
# Jira credentials stay on the runner — they never enter the sandbox.
#
# Runs on the CI runner BEFORE sandbox creation.
#
# Required environment variables:
#   ISSUE_URL          — Jira browse URL (https://<host>.atlassian.net/browse/PROJ-123)
#   JIRA_ISSUE_CONTEXT_FILE — runner path for the fetched issue context
#   JIRA_USER_EMAIL    — Jira account email for Basic auth
#   JIRA_TOKEN         — Jira Cloud API token
#   REPO_FULL_NAME     — target repo (owner/repo), used for pre-commit tool install
#   FULLSEND_FORGE     — "github" or "gitlab" (the target forge, NOT the source)
#
# Optional environment variables:
#   JIRA_BASE_URL      — Jira instance base URL; derived from ISSUE_URL when unset,
#                         cross-checked when set
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prescript-output.lib.sh
# BEGIN bundled: lib/prescript-output.lib.sh
# prescript-output.lib.sh — Write pre-script output protocol lines.
#
# The pre-script output protocol (fullsend docs/normative/prescript-output/v1,
# fullsend-ai/fullsend#4718) is the contract between `fullsend run` and a
# harness pre-script: the CLI exports FULLSEND_PRESCRIPT_OUTPUT naming a
# file, and the script appends key=value lines to it — `skipped=true` (plus
# an optional `reason`) stops the run before sandbox creation. Under a CLI
# that predates the protocol the variable is unset and writes are skipped,
# so the run proceeds — the protocol's version-skew contract.
#
# Source from a pre-script .src.sh:
#   source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"

# shellcheck shell=bash

[[ -n "${PRESCRIPT_OUTPUT_SH_LOADED:-}" ]] && return 0
PRESCRIPT_OUTPUT_SH_LOADED=1

# prescript_output KEY VALUE — append a protocol line, if the CLI
# supports the protocol. Values must be single-line (protocol grammar).
prescript_output() {
  if [[ -n "${FULLSEND_PRESCRIPT_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "${FULLSEND_PRESCRIPT_OUTPUT}"
  fi
}
# END bundled: lib/prescript-output.lib.sh

: "${ISSUE_URL:?ISSUE_URL must be set}"
: "${JIRA_ISSUE_CONTEXT_FILE:?JIRA_ISSUE_CONTEXT_FILE must be set}"
: "${JIRA_USER_EMAIL:?JIRA_USER_EMAIL must be set}"
: "${JIRA_TOKEN:?JIRA_TOKEN must be set}"

# Sanitize a value for safe use in GHA workflow commands (::error::, etc.).
# Strips newlines/carriage returns and escapes :: to prevent injection.
_sanitize_gha() {
  printf '%s' "$1" | tr -d '\n\r' | sed 's/%/%25/g; s/::/%3A%3A/g'
}

# ---------------------------------------------------------------------------
# Validate Jira issue URL
# ---------------------------------------------------------------------------
if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
  echo "::error::ISSUE_URL does not match expected Jira pattern: $(_sanitize_gha "${ISSUE_URL}")"
  exit 1
fi

JIRA_HOST="$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')"
case "${JIRA_HOST}" in
  *.atlassian.net) ;;
  *)
    echo "::error::Jira host '${JIRA_HOST}' is not in the allowed host list (*.atlassian.net)"
    exit 1
    ;;
esac

# Derive JIRA_BASE_URL from the issue URL and cross-check the env var.
PARSED_BASE_URL="https://${JIRA_HOST}"
while [[ -n "${JIRA_BASE_URL:-}" && "${JIRA_BASE_URL}" == */ ]]; do
  JIRA_BASE_URL="${JIRA_BASE_URL%/}"
done
if [[ -n "${JIRA_BASE_URL:-}" ]] && [[ "${JIRA_BASE_URL}" != "${PARSED_BASE_URL}" ]]; then
  echo "::error::JIRA_BASE_URL ('$(_sanitize_gha "${JIRA_BASE_URL}")') does not match ISSUE_URL host ('${PARSED_BASE_URL}')"
  exit 1
fi
JIRA_BASE_URL="${PARSED_BASE_URL}"

# Parse issue key and project from the URL.
ISSUE_KEY="$(echo "${ISSUE_URL}" | sed -E 's|.*/browse/||')"
PROJECT_KEY="${ISSUE_KEY%-*}"
ISSUE_NUM="${ISSUE_KEY##*-}"

echo "::notice::🔗 Jira source: ${ISSUE_URL} (project=${PROJECT_KEY}, key=${ISSUE_KEY})"

# ---------------------------------------------------------------------------
# Fetch issue context via fullsend CLI
# ---------------------------------------------------------------------------
ISSUE_CONTEXT_PATH="${JIRA_ISSUE_CONTEXT_FILE}"

if ! command -v fullsend >/dev/null 2>&1; then
  echo "::error::fullsend CLI not found — cannot fetch Jira issue"
  exit 1
fi

echo "Fetching Jira issue ${ISSUE_KEY}..."
if ! fullsend issues get --tracker jira \
  --project "${PROJECT_KEY}" --number "${ISSUE_NUM}" \
  --jira-url "${JIRA_BASE_URL}" --jira-email "${JIRA_USER_EMAIL}" \
  --token "${JIRA_TOKEN}" > "${ISSUE_CONTEXT_PATH}"; then
  echo "::error::Failed to fetch Jira issue ${ISSUE_KEY}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate the fetched context
# ---------------------------------------------------------------------------
if [[ ! -s "${ISSUE_CONTEXT_PATH}" ]]; then
  echo "::error::Jira issue context is empty"
  exit 1
fi

# Sanity-check: the response must be valid JSON.
if ! jq empty "${ISSUE_CONTEXT_PATH}" 2>/dev/null; then
  echo "::error::Jira issue context is not valid JSON"
  exit 1
fi

echo "Jira issue context written to ${ISSUE_CONTEXT_PATH}"

# ---------------------------------------------------------------------------
# Existing-PR check — intentionally omitted for Jira-sourced flows
# ---------------------------------------------------------------------------
# The forge pre-script (pre-code.src.sh) checks for existing human PRs
# linked to the issue via forge_list_prs_for_issue and skips the agent
# run to avoid stepping on human work.  That check searches for closing
# keywords (Fixes #N, Closes #N) on the TARGET forge.  Jira-sourced
# issues do not map 1:1 to a forge issue number — PRs referencing Jira
# work use the issue key (PROJ-42) not a forge issue reference (#N) —
# so forge_list_prs_for_issue would produce false negatives.  A Jira-
# aware existing-PR check requires cross-system linking (e.g., Jira
# development panel integration) which is out of scope for the initial
# Jira overlay.  The /fs-code --force override is still available via
# the forge pre-script for forge-native flows.

# ---------------------------------------------------------------------------
# Auto-detect and install pre-commit tool dependencies
# ---------------------------------------------------------------------------
# This section is shared with the forge pre-script — the target repo is
# the same regardless of whether the source issue is Jira or a forge.

# shellcheck source=lib/code-ops.lib.sh
# BEGIN bundled: lib/code-ops.lib.sh
# shellcheck shell=bash
# code-ops.lib.sh — Forge-dispatch wrapper for code agent operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${CODE_OPS_SH_LOADED:-}" ]] && return 0
CODE_OPS_SH_LOADED=1

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-code-ops.lib.sh
# shellcheck shell=bash
# github-code-ops.lib.sh — GitHub forge operations for code agent scripts.
#
# Bundled into pre-code.sh and post-code.sh via code-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by caller or forge_parse_issue_url):
#   REPO_FULL_NAME — owner/repo (e.g., "org/repo")
#   ISSUE_NUMBER   — issue number
#
# Expected env vars:
#   GH_TOKEN       — GitHub token with appropriate scopes

[[ -n "${GITHUB_CODE_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_CODE_OPS_SH_LOADED=1

# --- URL handling ---

forge_validate_issue_url() {
  local url="${1:-${ISSUE_URL:-}}"
  if [[ ! "${url}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitHub pattern: ${url}" >&2
    return 1
  fi
}

forge_parse_issue_url() {
  local url="${1:-${ISSUE_URL:-}}"
  REPO_FULL_NAME=$(echo "${url}" | sed 's|https://github.com/||; s|/issues/.*||')
  ISSUE_NUMBER=$(basename "${url}")
}

forge_extract_repo_from_url() {
  local url="$1"
  echo "${url}" | sed -E 's|https://github.com/([^/]+/[^/]+)/issues/.*|\1|'
}

forge_extract_issue_from_url() {
  local url="$1"
  echo "${url}" | sed -E 's|.*/issues/([0-9]+)$|\1|'
}

# --- Label operations ---

forge_add_label() {
  local label="$1"
  local target="${2:-issue}"
  local number="${3:-${ISSUE_NUMBER}}"
  if [ "${target}" = "pr" ]; then
    gh issue edit "${number}" --repo "${REPO_FULL_NAME}" \
      --add-label "${label}" 2>/dev/null || \
      gha_echo warning "Failed to apply ${label} label to PR #${number}"
  else
    gh api "repos/${REPO_FULL_NAME}/issues/${number}/labels" \
      -f "labels[]=${label}" --silent 2>/dev/null || true
  fi
}

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  gh label create "${name}" --repo "${REPO_FULL_NAME}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

# --- Comment operations ---

forge_post_issue_comment() {
  local body="$1"
  printf '%s' "${body}" | gh issue comment "${ISSUE_NUMBER}" \
    --repo "${REPO_FULL_NAME}" --body-file - 2>/dev/null
}

forge_post_pr_comment() {
  local target_pr="$1"
  local body="$2"
  gh pr comment "${target_pr}" \
    --repo "${REPO_FULL_NAME}" \
    --body "${body}" 2>/dev/null
}

# --- PR/MR lifecycle ---

forge_list_prs_for_issue() {
  local issue_number="$1"
  local bot_login="${2:-fullsend-ai[bot]}"
  local coder_bot_login="${3:-fullsend-ai-coder[bot]}"
  local owner="${REPO_FULL_NAME%%/*}"
  local name="${REPO_FULL_NAME##*/}"
  # Use closedByPullRequestsReferences to find only PRs with closing keywords
  # (Fixes #N, Closes #N, etc.) for this issue. This avoids false positives
  # from text-search matching (e.g., #1 matching #12 in a PR title).
  gh api graphql \
    -f owner="${owner}" -f name="${name}" -F number="${issue_number}" \
    -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) {
          closedByPullRequestsReferences(first: 50) {
            nodes {
              number
              url
              author { login }
              state
            }
          }
        }
      }
    }' --arg bot "${bot_login}" --arg coder "${coder_bot_login}" --jq '
    .data.repository.issue.closedByPullRequestsReferences.nodes
    | [.[] | select(.state == "OPEN")
           | select(.author.login != $bot
               and .author.login != $coder)]
    | .[] | "\(.number)\t\(.author.login)\t\(.url)"
  ' 2>/dev/null || true
}

forge_list_prs_for_branch() {
  local branch="$1"
  local owner="${REPO_FULL_NAME%%/*}"
  gh pr list --repo "${REPO_FULL_NAME}" --head "${branch}" \
    --state open --json number,headRepositoryOwner \
    --jq "[.[] | select(.headRepositoryOwner.login == \"${owner}\")] | .[0].number // empty" \
    2>/dev/null
}

forge_create_pr() {
  local base="$1"
  local head="$2"
  local title="$3"
  local body="$4"
  gh pr create \
    --repo "${REPO_FULL_NAME}" \
    --head "${head}" \
    --base "${base}" \
    --title "${title}" \
    --body "${body}"
}

forge_get_pr_url() {
  local target_pr="$1"
  gh pr view "${target_pr}" --repo "${REPO_FULL_NAME}" \
    --json url --jq '.url' 2>/dev/null || true
}

forge_get_pr_details() {
  local target_pr="$1"
  local fields="$2"
  gh pr view "${target_pr}" --repo "${REPO_FULL_NAME}" \
    --json "${fields}" 2>/dev/null
}

forge_assign_pr() {
  local target_pr="$1"
  local assignee="$2"
  local assign_err
  assign_err="$(gh pr edit "${target_pr}" --repo "${REPO_FULL_NAME}" \
    --add-assignee "${assignee}" 2>&1)" || {
    _pr_assignee_warn "Failed to assign PR #${target_pr} to ${assignee} — continuing"
    if [[ -n "${assign_err}" ]]; then
      _pr_assignee_warn "${assign_err}"
    fi
  }
}

# --- Repository operations ---

forge_get_default_branch() {
  local token="${1:-${PUSH_TOKEN:-}}"
  GH_TOKEN="${token}" gh api "repos/${REPO_FULL_NAME}" --jq '.default_branch' 2>/dev/null || echo 'main'
}

forge_set_push_remote() {
  local token="$1"
  git remote set-url origin \
    "https://x-access-token:${token}@github.com/${REPO_FULL_NAME}.git"
}

forge_check_remote_branch() {
  local branch="$1"
  git ls-remote origin "refs/heads/${branch}" 2>/dev/null | head -1 || true
}

forge_delete_remote_branch() {
  local branch="$1"
  local _del_output
  _del_output="$(git push origin --delete "${branch}" 2>&1)" || {
    # Sanitize before logging — git may echo the x-access-token:<token>@ remote URL.
    if declare -F print_sanitized_gha_log >/dev/null 2>&1; then
      print_sanitized_gha_log "${_del_output}"
    fi
    gha_echo warning "Failed to delete stale remote branch ${branch}"
  }
}

# --- Merge queue / auto-merge ---

forge_check_merge_queue() {
  local base_branch="$1"
  local owner="${REPO_FULL_NAME%%/*}"
  local name="${REPO_FULL_NAME##*/}"
  gh api graphql -f query="
    query { repository(owner: \"${owner}\", name: \"${name}\") {
      mergeQueue(branch: \"${base_branch}\") { id }
    }}" --jq '.data.repository.mergeQueue.id // empty' 2>/dev/null || true
}

forge_get_repo_merge_methods() {
  gh api "repos/${REPO_FULL_NAME}" \
    --jq '{s:.allow_squash_merge,m:.allow_merge_commit,r:.allow_rebase_merge}' 2>/dev/null || true
}

forge_enable_auto_merge() {
  local target_pr="$1"
  local method_flag="$2"
  local merge_output
  # shellcheck disable=SC2086
  if ! merge_output="$(gh pr merge "${target_pr}" --auto ${method_flag} \
    --repo "${REPO_FULL_NAME}" 2>&1)"; then
    print_sanitized_gha_log "${merge_output}"
    gha_echo warning "Failed to enable auto-merge on PR #${target_pr} — continuing"
  else
    print_sanitized_gha_log "${merge_output}"
  fi
}

# --- Issue operations ---

forge_get_issue_comments() {
  local raw
  if ! raw="$(gh api --paginate \
    "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/comments" 2>/dev/null)"; then
    echo '[]'
    return 0
  fi
  if [[ -z "${raw}" ]]; then
    echo '[]'
    return 0
  fi
  echo "${raw}" | jq -s 'add // []' 2>/dev/null || echo '[]'
}

forge_get_issue_details() {
  gh issue view "${ISSUE_NUMBER}" --repo "${REPO_FULL_NAME}" \
    --json assignees,author 2>/dev/null || true
}

# --- CI operations ---

forge_get_workflow_run_url() {
  local run_repo="${GITHUB_REPOSITORY:-${REPO_FULL_NAME}}"
  printf '%s/%s/actions/runs/%s' \
    "${GITHUB_SERVER_URL:-https://github.com}" \
    "${run_repo}" \
    "${GITHUB_RUN_ID:-unknown}"
}

# --- Output operations ---

forge_write_output() {
  local key="$1"
  local value="$2"
  echo "${key}=${value}" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# --- Workspace operations ---

forge_get_workspace_dir() {
  echo "${GITHUB_WORKSPACE:-}"
}

forge_get_repo_dir() {
  echo "${REPO_DIR:-${GITHUB_WORKSPACE:-}/target-repo}"
}

forge_append_path() {
  local dir="$1"
  echo "${dir}" >> "${GITHUB_PATH:-/dev/null}"
}
# END bundled: lib/github-code-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-code-ops.lib.sh
# shellcheck shell=bash
# gitlab-code-ops.lib.sh — GitLab forge operations for code agent scripts.
#
# Bundled into pre-code.sh and post-code.sh via code-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by caller or forge_parse_issue_url):
#   REPO_FULL_NAME — plain project path (e.g., "group/project")
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

[[ -n "${GITLAB_CODE_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_CODE_OPS_SH_LOADED=1

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

if ! declare -F gha_echo >/dev/null 2>&1; then
  gha_echo() { echo "::${1}::${2:-}"; }
fi

_gitlab_code_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call forge_parse_issue_url first" >&2
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

_gitlab_code_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call forge_parse_issue_url first" >&2
    return 1
  fi
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
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
    local _truncated
    _truncated=$(printf '%.200s' "${body}")
    echo "GitLab API error (HTTP ${http_code}): ${_truncated}" >&2
    return 1
  fi
  echo "${body}"
}

# --- URL handling ---

forge_validate_issue_url() {
  local url="${1:-${ISSUE_URL:-}}"
  if [[ ! "${url}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+/-/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitLab pattern: $(_gha_sanitize "${url}")" >&2
    return 1
  fi
  local host
  host=$(echo "${url}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  _validate_gitlab_host "${host}" || return 1
}

forge_parse_issue_url() {
  local url="${1:-${ISSUE_URL:-}}"
  GITLAB_HOST=$(echo "${url}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  REPO_FULL_NAME=$(echo "${url}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
  REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
  ISSUE_NUMBER=$(basename "${url}")
}

forge_extract_repo_from_url() {
  local url="$1"
  echo "${url}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|'
}

forge_extract_issue_from_url() {
  local url="$1"
  echo "${url}" | sed -E 's|.*/issues/([0-9]+)$|\1|'
}

# --- Label operations ---

forge_add_label() {
  local label="$1"
  local target="${2:-issue}"
  local number="${3:-${ISSUE_NUMBER}}"
  if [ "${target}" = "pr" ]; then
    # On GitLab, MRs use the same label update mechanism
    local mr_iid="${number}"
    _gitlab_code_api PUT "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" \
      --data-urlencode "add_labels=${label}" > /dev/null 2>/dev/null || \
      gha_echo warning "Failed to apply ${label} label to MR !${mr_iid}"
  else
    _gitlab_code_api PUT "/projects/${REPO_ENCODED}/issues/${number}" \
      --data-urlencode "add_labels=${label}" > /dev/null 2>/dev/null || true
  fi
}

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  local clean_color="${color#\#}"
  _gitlab_code_api POST "/projects/${REPO_ENCODED}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${clean_color}" > /dev/null 2>/dev/null || true
}

# --- Comment operations ---

forge_post_issue_comment() {
  local body="$1"
  _gitlab_code_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
    --data-urlencode "body=${body}" > /dev/null 2>/dev/null
}

forge_post_pr_comment() {
  local mr_iid="$1"
  local body="$2"
  _gitlab_code_api POST "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}/notes" \
    --data-urlencode "body=${body}" > /dev/null 2>/dev/null
}

# --- MR lifecycle ---

forge_list_prs_for_issue() {
  local issue_number="$1"
  local bot_login="${2:-}"
  local coder_bot_login="${3:-}"
  # GitLab API: search MRs referencing the issue. Best-effort — GitLab does not
  # have a direct "MRs linked to issue" endpoint. Fetch open MRs and filter for
  # closing keywords (Close, Fix, Resolve variants) targeting #<IID>. Plain
  # mentions without closing keywords are excluded to avoid false positives.
  local all_mrs="[]"
  local page=1 max_pages=10
  while [[ "${page}" -le "${max_pages}" ]]; do
    local batch
    batch=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests?state=opened&per_page=100&page=${page}" 2>/dev/null) || {
      if [ "${page}" -eq 1 ]; then
        gha_echo warning "forge_list_prs_for_issue: GitLab API failed on first page — failing closed"
        return 1
      fi
      break
    }
    local count
    count=$(echo "${batch}" | jq 'length' 2>/dev/null) || break
    [[ "${count}" -eq 0 ]] && break
    all_mrs=$(echo "${all_mrs}" "${batch}" | jq -s 'add') || break
    page=$((page + 1))
  done
  # Filter for MRs with closing keywords (Closes, Fixes, Resolves, etc.)
  # targeting #<IID>. Plain mentions without closing keywords are excluded
  # to avoid false positives (e.g., "Related: #42" should not block).
  echo "${all_mrs}" | jq -r --arg issue_number "${issue_number}" \
    --arg bot1 "${bot_login}" --arg bot2 "${coder_bot_login}" '
    [.[] | select(
      ((.title // "") | test("\\b(?:close[sd]?|closing|fix(?:e[sd])?|fixing|resolve[sd]?|resolving):?\\s+(?:(?:[a-zA-Z0-9._/-]+)?#\\d+(?:\\s+and\\s+|\\s*,\\s*|\\s+))*(?:[a-zA-Z0-9._/-]+)?#" + $issue_number + "(?:$|\\W)"; "i")) or
      ((.description // "") | test("\\b(?:close[sd]?|closing|fix(?:e[sd])?|fixing|resolve[sd]?|resolving):?\\s+(?:(?:[a-zA-Z0-9._/-]+)?#\\d+(?:\\s+and\\s+|\\s*,\\s*|\\s+))*(?:[a-zA-Z0-9._/-]+)?#" + $issue_number + "(?:$|\\W)"; "i"))
    ) | select(
      ((.source_branch // "") | test("^agent/" + $issue_number + "-") | not)
    ) | select(
      (if $bot1 != "" then (.author.username // "") != $bot1 else true end) and
      (if $bot2 != "" then (.author.username // "") != $bot2 else true end) and
      (.author.username // "" | test("\\[bot\\]$") | not) and
      (.author.username // "" | test("^fullsend") | not) and
      (.author.username // "" | test("_bot$") | not)
    )] | .[] | "\(.iid)\t\(.author.username)\t\(.web_url)"
  ' 2>/dev/null || true
}

forge_list_prs_for_branch() {
  local branch="$1"
  local branch_encoded
  branch_encoded=$(printf '%s' "${branch}" | jq -sRr @uri)
  local mrs
  mrs=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests?state=opened&source_branch=${branch_encoded}" 2>/dev/null) || return 1
  # Filter to same-project MRs only (exclude fork MRs) — mirrors the GitHub
  # implementation which filters by headRepositoryOwner.
  local project_id
  project_id=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}" 2>/dev/null | jq -r '.id // empty') || true
  if [[ -z "${project_id}" ]]; then
    gha_echo warning "Could not resolve project ID for fork-MR filtering — failing closed"
    return 1
  fi
  echo "${mrs}" | jq -r --arg pid "${project_id}" \
    '[.[] | select(.source_project_id == ($pid | tonumber))] | .[0].iid // empty'
}

forge_create_pr() {
  local base="$1"
  local head="$2"
  local title="$3"
  local body="$4"
  local response
  response=$(_gitlab_code_api_with_status POST "/projects/${REPO_ENCODED}/merge_requests" \
    --data-urlencode "source_branch=${head}" \
    --data-urlencode "target_branch=${base}" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description=${body}") || return 1
  local url
  url=$(echo "${response}" | jq -r '.web_url // empty')
  if [[ -z "${url}" ]]; then
    echo "GitLab API error: MR created but response missing web_url" >&2
    return 1
  fi
  echo "${url}"
}

forge_get_pr_url() {
  local mr_iid="$1"
  local mr_json
  mr_json=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" 2>/dev/null) || {
    echo ""
    return 0
  }
  echo "${mr_json}" | jq -r '.web_url // empty' 2>/dev/null || true
}

forge_get_pr_details() {
  local mr_iid="$1"
  local _fields="$2"  # accepted for interface parity but GitLab returns all fields
  _gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" 2>/dev/null
}

forge_assign_pr() {
  local mr_iid="$1"
  local assignee="$2"
  # Resolve assignee username to user ID for GitLab
  local user_json user_id
  local assignee_encoded
  assignee_encoded=$(printf '%s' "${assignee}" | jq -sRr @uri)
  user_json=$(_gitlab_code_api GET "/users?username=${assignee_encoded}" 2>/dev/null) || {
    _pr_assignee_warn "Failed to resolve GitLab user '${assignee}' — skipping assignment"
    return 0
  }
  user_id=$(echo "${user_json}" | jq -r '.[0].id // empty' 2>/dev/null)
  if [[ -z "${user_id}" ]]; then
    _pr_assignee_warn "GitLab user '${assignee}' not found — skipping assignment"
    return 0
  fi
  if ! _gitlab_code_api PUT "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" \
    --data-urlencode "assignee_ids[]=${user_id}" > /dev/null 2>/dev/null; then
    _pr_assignee_warn "Failed to assign MR !${mr_iid} to ${assignee} — continuing"
  fi
}

# --- Repository operations ---

forge_get_default_branch() {
  local token="${1:-${GITLAB_TOKEN:-}}"
  local project_json
  project_json=$(GITLAB_TOKEN="${token}" _gitlab_code_api GET "/projects/${REPO_ENCODED}" 2>/dev/null) || {
    echo 'main'
    return 0
  }
  echo "${project_json}" | jq -r '.default_branch // "main"' 2>/dev/null || echo 'main'
}

forge_set_push_remote() {
  local token="$1"
  git remote set-url origin \
    "https://oauth2:${token}@${GITLAB_HOST}/${REPO_FULL_NAME}.git"
}

forge_check_remote_branch() {
  local branch="$1"
  git ls-remote origin "refs/heads/${branch}" 2>/dev/null | head -1 || true
}

forge_delete_remote_branch() {
  local branch="$1"
  local _del_output
  _del_output="$(git push origin --delete "${branch}" 2>&1)" || {
    # Sanitize before logging — git may echo the oauth2:<token>@ remote URL.
    if declare -F print_sanitized_gha_log >/dev/null 2>&1; then
      print_sanitized_gha_log "${_del_output}"
    fi
    gha_echo warning "Failed to delete stale remote branch ${branch}"
  }
}

# --- Auto-merge ---

forge_check_merge_queue() {
  # GitLab does not have a merge queue equivalent; merge trains are configured
  # per-project but have no API query like GitHub's mergeQueue.
  echo ""
}

forge_get_repo_merge_methods() {
  local project_json
  project_json=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}" 2>/dev/null) || {
    echo ""
    return 0
  }
  local method
  method=$(echo "${project_json}" | jq -r '.merge_method // "merge"' 2>/dev/null)
  # Map GitLab merge_method to the same JSON shape as GitHub for compat
  case "${method}" in
    merge) echo '{"s":false,"m":true,"r":false}' ;;
    rebase_merge) echo '{"s":false,"m":false,"r":true}' ;;
    ff)    echo '{"s":false,"m":false,"r":true}' ;;
    *)     echo '{"s":false,"m":true,"r":false}' ;;
  esac
}

forge_enable_auto_merge() {
  local mr_iid="$1"
  local _method_flag="$2"

  # Safety guard: merge_when_pipeline_succeeds merges immediately when the
  # pipeline has already passed or no pipeline exists.  Match the GitHub path's
  # BLOCKED-state guard by requiring that the MR is not immediately mergeable.
  # Retry up to 3 times — new MRs may report "none" briefly.
  local mr_json pipeline_status _am_attempt
  for _am_attempt in 1 2 3; do
    mr_json=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" 2>/dev/null) || {
      gha_echo warning "Auto-merge: could not query MR !${mr_iid} — skipping"
      return 0
    }
    pipeline_status=$(echo "${mr_json}" | jq -r '.head_pipeline.status // "none"')

    case "${pipeline_status}" in
      running|pending|created|preparing|waiting_for_resource|scheduled)
        break
        ;;
      none)
        if [ "${_am_attempt}" -lt 3 ]; then
          echo "Auto-merge: MR !${mr_iid} pipeline status is 'none' (attempt ${_am_attempt}/3) — retrying in 5s..."
          sleep 5
          continue
        fi
        gha_echo warning "Auto-merge: MR !${mr_iid} has no pipeline after 3 attempts — skipping (would merge immediately)"
        return 0
        ;;
      success)
        break
        ;;
      failed|canceled)
        gha_echo warning "Auto-merge: MR !${mr_iid} pipeline status '${pipeline_status}' — skipping"
        return 0
        ;;
      *)
        gha_echo warning "Auto-merge: MR !${mr_iid} unrecognized pipeline status '${pipeline_status}' — skipping"
        return 0
        ;;
    esac
  done

  # BLOCKED guard (parity with GitHub's mergeStateStatus check)
  local merge_status
  merge_status=$(echo "${mr_json}" | jq -r '.detailed_merge_status // .merge_status // "unknown"')
  case "${merge_status}" in
    mergeable|can_be_merged)
      gha_echo warning "Auto-merge: MR !${mr_iid} is immediately mergeable — skipping. Requires merge request approvals or pipeline checks."
      return 0
      ;;
    not_approved|ci_must_pass|ci_still_running|discussions_not_resolved|blocked_status|need_rebase)
      ;;
    checking|unchecked|preparing)
      if [ "${pipeline_status}" = "success" ]; then
        gha_echo warning "Auto-merge: MR !${mr_iid} merge status '${merge_status}' not settled but pipeline passed — skipping (could merge immediately)"
        return 0
      fi
      ;;
    *)
      gha_echo warning "Auto-merge: MR !${mr_iid} unrecognized merge status '${merge_status}' — skipping"
      return 0
      ;;
  esac

  if [ "${pipeline_status}" = "success" ]; then
    echo "Auto-merge: MR !${mr_iid} pipeline passed but MR is blocked (${merge_status}) — arming auto-merge"
  fi

  if ! _gitlab_code_api PUT "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}/merge" \
    --data-urlencode "merge_when_pipeline_succeeds=true" > /dev/null 2>/dev/null; then
    gha_echo warning "Failed to enable auto-merge on MR !${mr_iid} — continuing"
  fi
}

# --- Issue operations ---

forge_get_issue_comments() {
  local notes="[]"
  local page=1 max_pages=50
  while [[ "${page}" -le "${max_pages}" ]]; do
    local batch
    batch=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=asc&page=${page}" 2>/dev/null) || break
    local count
    count=$(echo "${batch}" | jq 'length') || break
    [[ "${count}" -eq 0 ]] && break
    notes=$(echo "${notes}" "${batch}" | jq -s 'add') || break
    page=$((page + 1))
  done
  # Remap GitLab shape to match GitHub expected shape for pr-assignee.lib.sh;
  # exclude system notes (timeline events GitHub doesn't return).
  echo "${notes}" | jq '[.[] | select(.system != true) | {user: {login: .author.username}, body: .body}]' 2>/dev/null || echo '[]'
}

forge_get_issue_details() {
  local issue_json
  issue_json=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" 2>/dev/null) || {
    echo ""
    return 0
  }
  # Remap GitLab shape to match GitHub expected shape for pr-assignee.lib.sh
  echo "${issue_json}" | jq '{
    assignees: [(.assignees // [])[] | {login: .username}],
    author: {login: (.author.username // "")}
  }' 2>/dev/null || true
}

# --- CI operations ---

forge_get_workflow_run_url() {
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    local run_repo="${GITHUB_REPOSITORY:-${REPO_FULL_NAME}}"
    printf '%s/%s/actions/runs/%s' \
      "${GITHUB_SERVER_URL:-https://github.com}" "${run_repo}" "${GITHUB_RUN_ID}"
    return 0
  fi
  local server_url="${CI_SERVER_URL:-https://gitlab.com}"
  local project_path="${CI_PROJECT_PATH:-${REPO_FULL_NAME}}"
  local pipeline_id="${CI_PIPELINE_ID:-unknown}"
  local job_id="${CI_JOB_ID:-}"
  if [[ -n "${job_id}" ]]; then
    printf '%s/%s/-/jobs/%s' "${server_url}" "${project_path}" "${job_id}"
  else
    printf '%s/%s/-/pipelines/%s' "${server_url}" "${project_path}" "${pipeline_id}"
  fi
}

# --- Output operations ---

forge_write_output() {
  local key="$1"
  local value="$2"
  # GitLab CI uses artifacts or dotenv for output; write to GITHUB_OUTPUT
  # if available (hybrid compatibility), otherwise no-op.
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${key}=${value}" >> "${GITHUB_OUTPUT}"
  fi
}

# --- Workspace operations ---

forge_get_workspace_dir() {
  echo "${CI_PROJECT_DIR:-${GITHUB_WORKSPACE:-}}"
}

forge_get_repo_dir() {
  echo "${REPO_DIR:-${CI_PROJECT_DIR:-${GITHUB_WORKSPACE:-}/target-repo}}"
}

forge_append_path() {
  local dir="$1"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "${dir}" >> "${GITHUB_PATH}"
  fi
  # On GitLab CI, PATH is modified directly (already done by caller)
}
# END bundled: lib/gitlab-code-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/code-ops.lib.sh

TARGET_REPO="$(forge_get_repo_dir)"
RESOLVE_SCRIPT="${SCRIPT_DIR}/resolve-precommit-tools.py"
INSTALL_SCRIPT="${SCRIPT_DIR}/install-precommit-tools.sh"

WORKSPACE_DIR="$(forge_get_workspace_dir)"
if [ ! -f "${RESOLVE_SCRIPT}" ] || [ ! -f "${INSTALL_SCRIPT}" ]; then
  if [ -n "${WORKSPACE_DIR}" ]; then
    for _ws_candidate in "${WORKSPACE_DIR}/scripts" "${WORKSPACE_DIR}/.fullsend/scripts"; do
      if [ -f "${_ws_candidate}/resolve-precommit-tools.py" ] \
         && [ -f "${_ws_candidate}/install-precommit-tools.sh" ]; then
        RESOLVE_SCRIPT="${_ws_candidate}/resolve-precommit-tools.py"
        INSTALL_SCRIPT="${_ws_candidate}/install-precommit-tools.sh"
        break
      fi
    done
  fi
fi

if [ -f "${TARGET_REPO}/.pre-commit-config.yaml" ] \
   && { [ ! -f "${RESOLVE_SCRIPT}" ] || [ ! -f "${INSTALL_SCRIPT}" ]; }; then
  echo "::warning::Pre-commit tool auto-install skipped: companion scripts not found"
  echo "::warning::Expected ${RESOLVE_SCRIPT} and ${INSTALL_SCRIPT}"
  echo "::warning::Pre-commit hooks requiring system tools (e.g. lychee) may fail"
fi

if [ -f "${TARGET_REPO}/.pre-commit-config.yaml" ] \
   && [ -f "${RESOLVE_SCRIPT}" ] \
   && [ -f "${INSTALL_SCRIPT}" ]; then
  echo "Resolving pre-commit tool dependencies..."
  MANIFEST="$(mktemp)"
  LOCAL_REG="$(mktemp)"
  RESOLVE_ARGS=("${TARGET_REPO}")
  DEFAULT_BR="$(git -C "${TARGET_REPO}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')" || DEFAULT_BR=""
  if [ -n "${DEFAULT_BR}" ] \
     && git -C "${TARGET_REPO}" show "origin/${DEFAULT_BR}:.pre-commit-tools.yaml" > "${LOCAL_REG}" 2>/dev/null; then
    RESOLVE_ARGS+=("--local-registry" "${LOCAL_REG}")
  fi
  if python3 "${RESOLVE_SCRIPT}" "${RESOLVE_ARGS[@]}" > "${MANIFEST}"; then
    if [ -s "${MANIFEST}" ] && jq -e '.tools | length > 0' "${MANIFEST}" >/dev/null 2>&1; then
      bash "${INSTALL_SCRIPT}" "${MANIFEST}"
    else
      echo "No additional pre-commit tools needed"
    fi
  else
    echo "::warning::Pre-commit tool resolution failed — continuing without auto-install"
  fi
  rm -f "${MANIFEST}" "${LOCAL_REG}"
fi
export PATH="${HOME}/.local/bin:${PATH}"
forge_append_path "${HOME}/.local/bin"
