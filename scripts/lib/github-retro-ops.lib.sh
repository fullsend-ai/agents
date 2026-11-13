#!/usr/bin/env bash
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

# --- URL handling ---

_forge_validate_originating_url() {
  if [[ ! "${ORIGINATING_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/(issues|pull)/[0-9]+$ ]]; then
    echo "ERROR: ORIGINATING_URL does not match expected pattern: $(_gha_sanitize "${ORIGINATING_URL}")" >&2
    return 1
  fi
}
forge_validate_originating_url() {
  _forge_validate_originating_url
}

_forge_parse_originating_url() {
  # shellcheck disable=SC2034 # ORIGINATING_REPO consumed by callers after function returns
  ORIGINATING_REPO=$(echo "${ORIGINATING_URL}" | sed -E 's#https://github.com/##; s#/(issues|pull)/.*##')
  # shellcheck disable=SC2034 # ORIGINATING_NUMBER consumed by callers after function returns
  ORIGINATING_NUMBER=$(basename "${ORIGINATING_URL}")
}
forge_parse_originating_url() {
  _forge_parse_originating_url
}

# --- Token handling ---

_forge_mask_token() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::add-mask::${GH_TOKEN}"
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
