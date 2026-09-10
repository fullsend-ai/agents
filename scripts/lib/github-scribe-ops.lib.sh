#!/usr/bin/env bash
# shellcheck shell=bash
# github-scribe-ops.lib.sh — GitHub forge operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected env vars:
#   SCRIBE_REPO  — GitHub repository (owner/name)
#   GH_TOKEN     — GitHub token with issues read/write scope

[[ -n "${GITHUB_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_SCRIBE_OPS_SH_LOADED=1

# --- Pre-script: repo context ---

# Fetch all open items from the issues endpoint (paginated). GitHub's REST
# /issues endpoint includes pull requests — callers filter them out.
forge_fetch_open_issues_raw() {
  local repo="$1" output_file="$2"
  gh api --paginate "repos/${repo}/issues?state=open&per_page=100" \
    > "${output_file}"
}

# Filter raw issues response into the backlog format: remove PRs, extract
# fields, truncate bodies to 500 chars.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq -s '[.[][] | select(.pull_request == null) | {number, title, body, labels, milestone, url: .html_url}]' "${raw_file}" \
    | jq '[.[] | .body = ((.body // "")[:500] + if ((.body // "") | length) > 500 then "…" else "" end)]' \
    > "${backlog_file}"
}

# Count total paginated items (issues + PRs on GitHub).
forge_count_paginated_total() {
  local raw_file="$1"
  jq -s '[.[][]] | length' "${raw_file}"
}

# Fetch recently closed issues.
forge_list_closed_issues() {
  local repo="$1" output_file="$2" limit="$3"
  gh issue list --repo "${repo}" --state closed \
    --json number,title,labels,url --limit "${limit}" \
    > "${output_file}"
}

# Fetch open pull requests. Normalizes output to include headRefName.
forge_list_open_prs() {
  local repo="$1" output_file="$2" limit="$3" token="$4"
  GH_TOKEN="${token}" gh pr list --repo "${repo}" --state open \
    --json number,title,labels,url,headRefName --limit "${limit}" \
    > "${output_file}"
}

# Get repo-level open_issues_count (includes PRs on GitHub) for truncation
# detection. Returns empty string on failure so callers can fall back.
forge_get_issue_count() {
  local repo="$1"
  gh api "repos/${repo}" --jq '.open_issues_count' 2>/dev/null || echo ""
}

# Fetch the repo's doc tree (markdown files under docs/).
forge_get_repo_tree() {
  local repo="$1" token="$2" output_file="$3"
  GH_TOKEN="${token}" gh api "repos/${repo}/git/trees/main?recursive=1" \
    --jq '[.tree[] | select(.path | startswith("docs/") and (.path | endswith(".md"))) | .path]' \
    > "${output_file}" 2>/dev/null || echo '[]' > "${output_file}"
}

# --- Post-script: issue/comment operations ---

# Fetch all comments on an issue (paginated). Returns a flat JSON array.
forge_list_issue_comments() {
  local repo="$1" issue_num="$2"
  gh api --paginate "repos/${repo}/issues/${issue_num}/comments" 2>/dev/null \
    | jq -s '[.[][] | {body}]'
}

# Post a comment on an issue. Body is read from stdin.
forge_post_issue_comment() {
  local repo="$1" issue_num="$2"
  gh issue comment "${issue_num}" --repo "${repo}" --body-file -
}

# Create a new issue with labels. Body is read from stdin. Returns the
# issue URL. Falls back to label-less creation if labels don't exist.
forge_create_issue() {
  local repo="$1" title="$2" labels="$3"
  local url body_file
  body_file=$(mktemp)
  cat > "${body_file}"
  url=$(gh issue create --repo "${repo}" --title "${title}" \
    --label "${labels}" --body-file "${body_file}" 2>/dev/null) || \
  url=$(gh issue create --repo "${repo}" --title "${title}" --body-file "${body_file}")
  rm -f "${body_file}"
  if [[ -z "${url}" ]]; then
    echo "ERROR: forge_create_issue: failed to create issue or missing URL in response" >&2
    return 1
  fi
  echo "${url}"
}

# Return the base URL for linking to issues.
forge_issue_url_base() {
  local repo="$1"
  echo "https://github.com/${repo}/issues"
}

# Return the CI run URL for notifications.
forge_run_url() {
  echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-${1}}/actions/runs/${GITHUB_RUN_ID:-0}"
}
