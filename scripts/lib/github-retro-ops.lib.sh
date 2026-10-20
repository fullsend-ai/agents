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

forge_validate_originating_url() {
  if [[ ! "${ORIGINATING_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/(issues|pull)/[0-9]+$ ]]; then
    echo "ERROR: ORIGINATING_URL does not match expected pattern: $(_gha_sanitize "${ORIGINATING_URL}")" >&2
    return 1
  fi
}

forge_parse_originating_url() {
  # shellcheck disable=SC2034 # ORIGINATING_REPO consumed by callers after function returns
  ORIGINATING_REPO=$(echo "${ORIGINATING_URL}" | sed -E 's#https://github.com/##; s#/(issues|pull)/.*##')
  # shellcheck disable=SC2034 # ORIGINATING_NUMBER consumed by callers after function returns
  ORIGINATING_NUMBER=$(basename "${ORIGINATING_URL}")
}

# --- Token handling ---

forge_mask_token() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::add-mask::${GH_TOKEN}"
  fi
}

forge_require_token() {
  : "${GH_TOKEN:?GH_TOKEN is required}"
}

# --- Config workspace ---

forge_get_config_workspace() {
  echo "${GITHUB_WORKSPACE:-/tmp}"
}

# --- Comment limits ---

forge_get_comment_max_len() {
  echo "65000"
}

# --- Labels ---

# Upsert a label (--force is idempotent). Failures are warned, not silent,
# so missing triage routing is visible in workflow logs. The caller still
# proceeds to file the issue even when label creation fails.
forge_create_label() {
  local repo="$1" name="$2" description="$3" color="$4"
  local err_file
  err_file=$(mktemp)
  if ! gh label create "${name}" --repo "${repo}" \
      --description "${description}" --color "${color}" \
      --force >"${err_file}" 2>&1; then
    echo "::warning::failed to create/verify $(_gha_sanitize "${name}") label in $(_gha_sanitize "${repo}") — issue may not be routed for triage: $(_gha_sanitize "$(cat "${err_file}")")"
  fi
  rm -f "${err_file}"
}

# --- Issues ---

# Create an issue. Stderr is kept out of the returned URL so callers can
# treat stdout as a URL. Any stderr on success is logged as a warning.
forge_create_issue() {
  local repo="$1" title="$2" body="$3" label="$4"
  local err_file url
  err_file=$(mktemp)
  if ! url=$(gh issue create \
    --repo "${repo}" \
    --title "${title}" \
    --body "${body}" \
    --label "${label}" 2>"${err_file}"); then
    local err
    err=$(cat "${err_file}")
    rm -f "${err_file}"
    echo "${url:+${url} }${err}"
    return 1
  fi
  if [[ -s "${err_file}" ]]; then
    echo "::warning::gh issue create stderr for $(_gha_sanitize "${repo}"): $(_gha_sanitize "$(cat "${err_file}")")" >&2
  fi
  rm -f "${err_file}"
  printf '%s\n' "${url}"
}

# Check whether label is present on a just-created issue. Distinguishes
# "could not read labels" from "label missing" so a view failure is not
# reported as a dropped label. Always returns 0 — warnings are non-fatal.
forge_verify_issue_label() {
  local repo="$1" issue_url="$2" label="$3"
  local issue_num labels_out rc=0
  issue_num=$(basename "${issue_url}")
  labels_out=$(gh issue view "${issue_num}" --repo "${repo}" \
    --json labels -q '.labels[].name' 2>&1) || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo "::warning::unable to verify $(_gha_sanitize "${label}") label on $(_gha_sanitize "${issue_url}"): $(_gha_sanitize "${labels_out}")"
    return 0
  fi
  if ! printf '%s\n' "${labels_out}" | grep -qxF "${label}"; then
    echo "::warning::$(_gha_sanitize "${label}") label not applied to $(_gha_sanitize "${issue_url}") — manual triage may be needed"
  fi
}

# --- Comments ---

forge_post_comment() {
  local repo="$1" number="$2" body="$3"
  jq -nc --arg body "${body}" '{body: $body}' | gh api \
    "repos/${repo}/issues/${number}/comments" \
    --input - 2>&1
}
