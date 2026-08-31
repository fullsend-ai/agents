#!/usr/bin/env bash
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
source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"

: "${ISSUE_URL:?ISSUE_URL must be set}"
: "${JIRA_ISSUE_CONTEXT_FILE:?JIRA_ISSUE_CONTEXT_FILE must be set}"
: "${JIRA_USER_EMAIL:?JIRA_USER_EMAIL must be set}"
: "${JIRA_TOKEN:?JIRA_TOKEN must be set}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME must be set}"

# Sanitize a value for safe use in GHA workflow commands (::error::, etc.).
# Strips ANSI escapes, newlines/carriage returns, and escapes :: to prevent injection.
_gha_sanitize() {
  printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'
}

# ---------------------------------------------------------------------------
# Validate Jira issue URL
# ---------------------------------------------------------------------------
if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
  echo "::error::ISSUE_URL does not match expected Jira pattern: $(_gha_sanitize "${ISSUE_URL}")"
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
  echo "::error::JIRA_BASE_URL ('$(_gha_sanitize "${JIRA_BASE_URL}")') does not match ISSUE_URL host ('${PARSED_BASE_URL}')"
  exit 1
fi
JIRA_BASE_URL="${PARSED_BASE_URL}"

# Parse issue key and project from the URL.
ISSUE_KEY="$(echo "${ISSUE_URL}" | sed -E 's|.*/browse/||')"
PROJECT_KEY="${ISSUE_KEY%-*}"
ISSUE_NUM="${ISSUE_KEY##*-}"

echo "::notice::🔗 Jira source: $(_gha_sanitize "${ISSUE_URL}") (project=$(_gha_sanitize "${PROJECT_KEY}"), key=$(_gha_sanitize "${ISSUE_KEY}"))"

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
source "${SCRIPT_DIR}/lib/code-ops.lib.sh"

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
