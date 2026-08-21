#!/usr/bin/env bash
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

if ! declare -F gha_echo >/dev/null 2>&1; then
  gha_echo() { echo "::${1}::${2:-}"; }
fi

_gitlab_code_api() {
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

_gitlab_code_api_with_status() {
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
    echo "ERROR: ISSUE_URL does not match expected GitLab pattern: ${url}" >&2
    return 1
  fi
  local host
  host=$(echo "${url}" | sed -E 's|^https://([^/]+)/.*|\1|')
  # Allowed GitLab hosts. To support a self-hosted instance, add it here
  # AND in the network policy (policies/gitlab/code.yaml).
  case "${host}" in
    gitlab.com|gitlab.cee.redhat.com) ;;
    *) echo "ERROR: GitLab host '${host}' is not in the allowed host list (see gitlab-code-ops.lib.sh and policies/gitlab/code.yaml)" >&2; return 1 ;;
  esac
}

forge_parse_issue_url() {
  local url="${1:-${ISSUE_URL:-}}"
  GITLAB_HOST=$(echo "${url}" | sed -E 's|^https://([^/]+)/.*|\1|')
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
