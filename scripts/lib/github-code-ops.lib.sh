#!/usr/bin/env bash
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

forge_remove_label() {
  local label="$1"
  local number="${2:-${ISSUE_NUMBER}}"
  # URL-encode the label for the path segment (spaces, slashes, etc.)
  local encoded_label
  encoded_label="$(printf '%s' "${label}" | jq -sRr @uri)"
  gh api "repos/${REPO_FULL_NAME}/issues/${number}/labels/${encoded_label}" \
    -X DELETE --silent 2>/dev/null || true
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
