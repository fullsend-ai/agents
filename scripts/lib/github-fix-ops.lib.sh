#!/usr/bin/env bash
# shellcheck shell=bash
# github-fix-ops.lib.sh — GitHub forge operations for fix agent scripts.
#
# Bundled into pre-fix.sh and post-fix.sh via fix-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by caller):
#   REPO_FULL_NAME — owner/repo (e.g., "org/repo")
#   PR_NUMBER      — pull request number
#
# Expected env vars:
#   GH_TOKEN       — GitHub token with appropriate scopes

[[ -n "${GITHUB_FIX_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_FIX_OPS_SH_LOADED=1

# forge_push_branch: a plain git push, or with GITHUB_SIGNED_COMMITS=true the
# API publish that gets the commits signed by GitHub.
# shellcheck source=github-signed-push.lib.sh
source "${BASH_SOURCE[0]%/*}/github-signed-push.lib.sh"

if ! declare -F gha_echo >/dev/null 2>&1; then
  gha_echo() {
    local lvl="$1"; shift
    local msg="${*//::/ }"
    msg="${msg//%0A/}"; msg="${msg//%0a/}"
    msg="${msg//%0D/}"; msg="${msg//%0d/}"
    printf '::%s::%s\n' "${lvl}" "${msg}"
  }
fi

# --- PR/MR operations ---

forge_validate_pr_url() {
  local url="${1:-${PR_URL:-}}"
  if [[ ! "${url}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/pull/[1-9][0-9]*$ ]]; then
    echo "ERROR: PR_URL does not match expected GitHub pattern: ${url}" >&2
    return 1
  fi
}

forge_parse_pr_url() {
  local url="${1:-${PR_URL:-}}"
  REPO_FULL_NAME=$(echo "${url}" | sed 's|https://github.com/||; s|/pull/.*||')
  # shellcheck disable=SC2034
  PR_NUMBER=$(basename "${url}")
}

forge_get_pr_head_ref() {
  local pr_number="$1"
  GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json headRefName --jq '.headRefName' 2>/dev/null
}

# forge_get_pr_base_branch PR_NUMBER — PR base branch (not the repo default).
# Empty on API failure; callers fall back to TARGET_BRANCH / main.
forge_get_pr_base_branch() {
  local pr_number="$1"
  GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json baseRefName --jq '.baseRefName // empty' 2>/dev/null
}

# forge_get_pr_merge_state PR_NUMBER — GitHub GraphQL MergeableState
# (MERGEABLE | CONFLICTING | UNKNOWN). Prints "unknown" on API failure or
# empty response so callers never treat a missing signal as a conflict.
forge_get_pr_merge_state() {
  local pr_number="$1"
  local mergeable
  mergeable="$(GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json mergeable --jq '.mergeable // empty' 2>/dev/null)" || {
    echo "unknown"
    return 0
  }
  if [ -z "${mergeable}" ]; then
    echo "unknown"
    return 0
  fi
  echo "${mergeable}"
}

# forge_pr_has_merge_conflict PR_NUMBER — return 0 only when GitHub reports
# mergeable=CONFLICTING. BLOCKED / BEHIND / UNSTABLE / UNKNOWN / MERGEABLE
# and API failures are not conflicts (issue #1518).
forge_pr_has_merge_conflict() {
  local pr_number="$1"
  local mergeable
  mergeable="$(forge_get_pr_merge_state "${pr_number}")" || return 1
  [ "${mergeable}" = "CONFLICTING" ]
}

# forge_get_pr_labels PR_NUMBER — the PR's live label names, one per line.
# Returns non-zero on API failure so callers can tell it apart from a PR
# with no labels.
forge_get_pr_labels() {
  local pr_number="$1"
  GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json labels --jq '.labels[].name' 2>/dev/null
}

# --- Push operations ---

forge_set_push_remote() {
  local token="$1"
  git remote set-url origin \
    "https://x-access-token:${token}@github.com/${REPO_FULL_NAME}.git"
}

forge_setup_push_token() {
  local token="$1"
  export GH_TOKEN="${token}"
}

forge_mask_token() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    local token="${1:-${GH_TOKEN:-}}"
    echo "::add-mask::${token}"
  fi
}

# --- Label operations ---

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  gh label create "${name}" --repo "${REPO_FULL_NAME}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

forge_add_pr_label() {
  local pr_number="$1"
  local label="$2"
  gh pr edit "${pr_number}" --repo "${REPO_FULL_NAME}" \
    --add-label "${label}" 2>/dev/null || true
}

# --- Comment operations ---

forge_post_pr_comment() {
  local pr_number="$1"
  local body="$2"
  gh pr comment "${pr_number}" \
    --repo "${REPO_FULL_NAME}" \
    --body "${body}"
}

# --- Workspace operations ---

forge_get_workflow_run_url() {
  local run_repo="${GITHUB_REPOSITORY:-${REPO_FULL_NAME}}"
  printf '%s/%s/actions/runs/%s' \
    "${GITHUB_SERVER_URL:-https://github.com}" \
    "${run_repo}" \
    "${GITHUB_RUN_ID:-unknown}"
}

forge_get_workspace_dir() {
  echo "${GITHUB_WORKSPACE:-}"
}

forge_append_path() {
  local dir="$1"
  echo "${dir}" >> "${GITHUB_PATH:-/dev/null}"
}
