#!/usr/bin/env bash
# Pre-script: validate workflow_dispatch inputs before the agent runs.
#
# Prevents malformed or malicious event_payload from reaching the sandbox.
# Runs on the CI runner BEFORE sandbox creation.
#
# Skip signalling uses the pre-script output protocol
# (fullsend docs/normative/prescript-output/v1, fullsend-ai/fullsend#4718):
# when an open human PR already addresses the issue, this script writes
# skipped=true to the file named by FULLSEND_PRESCRIPT_OUTPUT and
# fullsend run stops before creating the sandbox. Under a CLI that
# predates the protocol the variable is unset and the write is skipped —
# the run proceeds, which matches the pre-protocol behavior.
#
# Required environment variables (set by the workflow):
#   ISSUE_NUMBER       — must be a positive integer
#   REPO_FULL_NAME     — must be owner/repo format
#   ISSUE_URL          — must be a valid issue URL for the forge
#   FULLSEND_FORGE     — "github" or "gitlab"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prescript-output.lib.sh
source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"
# shellcheck source=lib/code-ops.lib.sh
source "${SCRIPT_DIR}/lib/code-ops.lib.sh"

echo "::notice::🔗 Code target: ${ISSUE_URL:-}"

errors=0

if [[ ! "${ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::ISSUE_NUMBER must be a positive integer, got: '${ISSUE_NUMBER:-}'"
  errors=$((errors + 1))
fi

if [[ ! "${REPO_FULL_NAME:-}" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+$ ]]; then
  echo "::error::REPO_FULL_NAME must be owner/repo (or group/subgroup/project) format, got: '${REPO_FULL_NAME:-}'"
  errors=$((errors + 1))
fi

if ! forge_validate_issue_url "${ISSUE_URL:-}"; then
  echo "::error::ISSUE_URL format invalid, got: '${ISSUE_URL:-}'"
  errors=$((errors + 1))
fi

URL_REPO="$(forge_extract_repo_from_url "${ISSUE_URL:-}" 2>/dev/null || true)"
URL_ISSUE="$(forge_extract_issue_from_url "${ISSUE_URL:-}" 2>/dev/null || true)"

if [[ -n "${URL_REPO}" && "${URL_REPO}" != "${REPO_FULL_NAME:-}" ]]; then
  echo "::error::REPO_FULL_NAME does not match issue URL repo ('${REPO_FULL_NAME:-}' vs '${URL_REPO}')"
  errors=$((errors + 1))
fi
if [[ -n "${URL_ISSUE}" && "${URL_ISSUE}" != "${ISSUE_NUMBER:-}" ]]; then
  echo "::error::ISSUE_NUMBER does not match issue URL number ('${ISSUE_NUMBER:-}' vs '${URL_ISSUE}')"
  errors=$((errors + 1))
fi

if [[ "${errors}" -gt 0 ]]; then
  echo "::error::Input validation failed with ${errors} error(s). Aborting."
  exit 1
fi

echo "Input validation passed:"
echo "  ISSUE_NUMBER=${ISSUE_NUMBER}"
echo "  REPO_FULL_NAME=${REPO_FULL_NAME}"
echo "  ISSUE_URL=${ISSUE_URL}"

# GitLab needs REPO_ENCODED and GITLAB_HOST for API calls — set them before
# any forge function that hits the API (forge_list_prs_for_issue, labels, etc.).
# Always derive GITLAB_HOST from the validated ISSUE_URL. If GITLAB_HOST is
# pre-set in the environment, verify it matches the URL host to prevent
# token exfiltration to an unintended host.
if [ "${FULLSEND_FORGE}" = "gitlab" ]; then
  # shellcheck disable=SC2034
  REPO_ENCODED="$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)"
  if [[ -n "${ISSUE_URL:-}" ]]; then
    _url_host="$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')"
    if [[ -n "${GITLAB_HOST:-}" && "${GITLAB_HOST}" != "${_url_host}" ]]; then
      echo "::error::GITLAB_HOST '${GITLAB_HOST}' does not match issue URL host '${_url_host}'"
      exit 1
    fi
    GITLAB_HOST="${_url_host}"
  fi
  GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
fi

# ---------------------------------------------------------------------------
# Check for existing human PRs linked to this issue
# ---------------------------------------------------------------------------
# Skip if the forge-specific token is not available (best-effort check).
if { [ "${FULLSEND_FORGE}" = "github" ] && [ -z "${GH_TOKEN:-}" ]; } || \
   { [ "${FULLSEND_FORGE}" = "gitlab" ] && [ -z "${GITLAB_TOKEN:-}" ]; }; then
  echo "No ${FULLSEND_FORGE} token set — skipping existing-PR check"
  exit 0
fi

# Allow override when the trigger comment is `/fs-code --force` or CODE_FORCE
# is set. --force counts only as the command's flag token on the first line —
# the same first-line tokenization the dispatch router uses — so a comment
# merely mentioning --force (or a pasted log containing it) cannot bypass
# the existing-PR check.
FORCE_WORD=""
if [[ -n "${COMMENT_BODY:-}" ]]; then
  FORCE_WORD="$(printf '%s\n' "${COMMENT_BODY}" | head -1 | tr -d '\r' | awk '{print $2}')"
fi
echo "Evaluating force override: CODE_FORCE='${CODE_FORCE:-}' COMMENT_BODY='${COMMENT_BODY:-}'"
if [[ "${CODE_FORCE:-}" == "true" ]] || [[ "${FORCE_WORD}" == "--force" ]]; then
  echo "Force override — skipping existing-PR check"
  exit 0
fi

BOT_LOGIN="fullsend-ai[bot]"
CODER_BOT_LOGIN="fullsend-ai-coder[bot]"

echo "Checking for existing open PRs linked to issue #${ISSUE_NUMBER}..."

HUMAN_PR_LINES="$(forge_list_prs_for_issue "${ISSUE_NUMBER}" "${BOT_LOGIN}" "${CODER_BOT_LOGIN}")"

if [[ -n "${HUMAN_PR_LINES}" ]]; then
  # Parse the first PR for the notice.
  FIRST_PR_NUM="$(echo "${HUMAN_PR_LINES}" | head -1 | cut -f1)"
  FIRST_PR_AUTHOR="$(echo "${HUMAN_PR_LINES}" | head -1 | cut -f2)"

  # GitLab uses ! for MR references; GitHub uses #.
  _pr_prefix="#"
  if [ "${FULLSEND_FORGE}" = "gitlab" ]; then
    _pr_prefix="!"
  fi

  echo "::notice::Found existing human PR ${_pr_prefix}${FIRST_PR_NUM} by @${FIRST_PR_AUTHOR}"

  # Apply pr-open label to signal work is already underway.
  forge_create_label "pr-open" "An open PR already addresses this issue" "D4C5F9"
  forge_add_label "pr-open"

  # Build a markdown list of existing PRs.
  PR_LIST_MD=""
  while IFS=$'\t' read -r pr_num pr_author _pr_url; do
    PR_LIST_MD="${PR_LIST_MD}
- ${_pr_prefix}${pr_num} by @${pr_author}"
  done <<< "${HUMAN_PR_LINES}"

  SKIP_COMMENT="An open PR already addresses this issue — skipping automated implementation.
${PR_LIST_MD}

To override, comment \`/fs-code --force\` on this issue.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-code check</sub>"

  forge_post_issue_comment "${SKIP_COMMENT}" || true

  echo "Skipping code agent — existing PR(s) found for issue #${ISSUE_NUMBER}"
  prescript_output "skipped" "true"
  prescript_output "reason" "open PR ${_pr_prefix}${FIRST_PR_NUM} by @${FIRST_PR_AUTHOR} already addresses issue #${ISSUE_NUMBER}"
  exit 0
fi

echo "No existing human PRs found — proceeding with code agent"

# ---------------------------------------------------------------------------
# Auto-detect and install pre-commit tool dependencies
# ---------------------------------------------------------------------------
TARGET_REPO="$(forge_get_repo_dir)"
RESOLVE_SCRIPT="${SCRIPT_DIR}/resolve-precommit-tools.py"
INSTALL_SCRIPT="${SCRIPT_DIR}/install-precommit-tools.sh"

# Fallback: these companion scripts were never migrated into this repo
# during the ADR 0058 extraction, so the BASH_SOURCE-relative lookup above
# always misses. The reusable workflow's "Prepare workspace" step always
# materializes the full scripts/ directory (from fullsend's own scaffold)
# at ${GITHUB_WORKSPACE}/scripts/ (per-org) or ${GITHUB_WORKSPACE}/.fullsend/scripts/
# (per-repo). Try those paths when the BASH_SOURCE-relative lookup misses.
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

# Warn instead of silently skipping when the repo needs the auto-install but
# the companions are missing everywhere — a silent skip here surfaces later
# as a confusing "Executable X not found" pre-commit failure.
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
