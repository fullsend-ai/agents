#!/usr/bin/env bash
# shellcheck shell=bash
# gitlab-fix-ops.lib.sh — GitLab forge operations for fix agent scripts.
#
# Bundled into pre-fix.sh and post-fix.sh via fix-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by caller or forge_parse_pr_url):
#   REPO_FULL_NAME — plain project path (e.g., "group/project")
#   REPO_ENCODED   — URL-encoded project path (e.g., "group%2Fproject")
#   PR_NUMBER      — merge request IID
#   GITLAB_HOST    — API host (e.g., "gitlab.com")
#
# Expected env vars:
#   PR_URL         — HTML URL of the merge request
#   GITLAB_TOKEN   — GitLab personal/project access token
#
# Token scopes: GITLAB_TOKEN requires minimum scopes:
#   - api (read/write merge requests, labels, notes)

[[ -n "${GITLAB_FIX_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_FIX_OPS_SH_LOADED=1

if ! declare -F gha_echo >/dev/null 2>&1; then
  gha_echo() {
    local lvl="$1"; shift
    local msg="${*//::/ }"
    msg="${msg//%0A/}"; msg="${msg//%0a/}"
    msg="${msg//%0D/}"; msg="${msg//%0d/}"
    printf '::%s::%s\n' "${lvl}" "${msg}"
  }
fi

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

# --- PR/MR operations ---

forge_validate_pr_url() {
  local url="${1:-${PR_URL:-}}"
  if [[ ! "${url}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+){2,}/-/merge_requests/[1-9][0-9]*$ ]]; then
    echo "ERROR: PR_URL does not match expected GitLab MR pattern: ${url}" >&2
    return 1
  fi
  local host
  host=$(echo "${url}" | sed -E 's|^https://([^/]+)/.*|\1|')
  # Allowed GitLab hosts. To support a self-hosted instance, add it here,
  # in process-fix-result.py (ALLOWED_GITLAB_HOSTS), AND in the network
  # policy (policies/gitlab/fix.yaml).
  case "${host}" in
    gitlab.com|gitlab.cee.redhat.com) ;;
    *) echo "ERROR: GitLab host '${host}' is not in the allowed host list (see gitlab-fix-ops.lib.sh and policies/gitlab/fix.yaml)" >&2; return 1 ;;
  esac
}

forge_parse_pr_url() {
  local url="${1:-${PR_URL:-}}"
  GITLAB_HOST=$(echo "${url}" | sed -E 's|^https://([^/]+)/.*|\1|')
  REPO_FULL_NAME=$(echo "${url}" | sed -E 's|^https://[^/]+/(.+)/-/merge_requests/[0-9]+$|\1|')
  REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
  # shellcheck disable=SC2034
  PR_NUMBER=$(basename "${url}")
}

forge_get_pr_head_ref() {
  local pr_number="$1"
  (
    # shellcheck disable=SC2030
    GITLAB_TOKEN="${PUSH_TOKEN:-${GITLAB_TOKEN:-}}"
    _gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${pr_number}" 2>/dev/null
  ) | jq -r '.source_branch // empty'
}

# --- Push operations ---

forge_set_push_remote() {
  local token="$1"
  [[ -n "${GITLAB_HOST:-}" ]] || { echo "ERROR: GITLAB_HOST is not set" >&2; return 1; }
  git remote set-url origin \
    "https://oauth2:${token}@${GITLAB_HOST}/${REPO_FULL_NAME}.git"
}

forge_setup_push_token() {
  local token="$1"
  # shellcheck disable=SC2031
  export GITLAB_TOKEN="${token}"
}

forge_mask_token() {
  # ::add-mask:: is GHA-specific; skip on GitLab CI to avoid printing tokens
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    local token="${1:-${GITLAB_TOKEN:-}}"
    echo "::add-mask::${token}"
  fi
}

# --- Label operations ---

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  local clean_color="${color#\#}"
  _gitlab_api POST "/projects/${REPO_ENCODED}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${clean_color}" > /dev/null 2>/dev/null || true
}

forge_add_pr_label() {
  local pr_number="$1"
  local label="$2"
  _gitlab_api PUT "/projects/${REPO_ENCODED}/merge_requests/${pr_number}" \
    --data-urlencode "add_labels=${label}" > /dev/null 2>/dev/null || true
}

# --- Comment operations ---

forge_post_pr_comment() {
  local mr_iid="$1"
  local body="$2"
  _gitlab_api POST "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}/notes" \
    --data-urlencode "body=${body}" > /dev/null 2>/dev/null
}

# --- Workspace operations ---

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

forge_get_workspace_dir() {
  echo "${CI_PROJECT_DIR:-${GITHUB_WORKSPACE:-}}"
}

forge_append_path() {
  local dir="$1"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "${dir}" >> "${GITHUB_PATH}"
  fi
  # On GitLab CI, PATH is modified directly (already done by caller)
}
