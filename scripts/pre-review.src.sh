#!/usr/bin/env bash
# pre-review.sh — Validate review inputs before the agent runs.
#
# Runs on the host via the harness pre_script mechanism.
#
# Required environment variables (set by the harness forge section):
#   PR_URL         — HTML URL of the PR/MR
#   FULLSEND_FORGE — "github" or "gitlab"
#
# Optional environment variables:
#   REVIEW_TOKEN        — token for PR state checks and comments
#   REVIEW_SKIP_AUTHORS — comma-separated author list to skip
set -euo pipefail

: "${PR_URL:?PR_URL must be set}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/review-ops.lib.sh
source "${SCRIPT_DIR}/lib/review-ops.lib.sh"

forge_validate_pr_url
echo "::notice::🔗 Review target: $(_gha_sanitize "${PR_URL}")"
forge_parse_pr_url

echo "Input validation passed:"
echo "  PR_NUMBER=${PR_NUMBER}"
echo "  REPO=${REPO}"
echo "  PR_URL=${PR_URL}"

# ---------------------------------------------------------------------------
# Check PR state — skip review on merged or closed PRs
# ---------------------------------------------------------------------------
if [[ -z "${REVIEW_TOKEN:-}" ]]; then
  echo "No token available — skipping PR state check"
  exit 0
fi

PR_STATE="$(forge_get_pr_state)"

if [[ -n "${PR_STATE}" && "${PR_STATE}" != "OPEN" ]]; then
  echo "::notice::PR #${PR_NUMBER} is ${PR_STATE} — skipping review"

  STATE_LOWER="$(echo "${PR_STATE}" | tr '[:upper:]' '[:lower:]')"
  COMMENT_BODY="Review skipped — this PR is already **${STATE_LOWER}**.

The \`/fs-review\` command only reviews open PRs/MRs.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-review check</sub>"

  forge_post_comment "${COMMENT_BODY}" 2>/dev/null || true

  exit 0
fi

# ---------------------------------------------------------------------------
# Check author skip list — exit early if PR author is in REVIEW_SKIP_AUTHORS
# ---------------------------------------------------------------------------
if [[ -n "${REVIEW_SKIP_AUTHORS:-}" ]]; then
  PR_AUTHOR="$(forge_get_pr_author)"

  if [[ -n "${PR_AUTHOR}" ]]; then
    IFS=',' read -ra _SKIP_LIST <<< "${REVIEW_SKIP_AUTHORS}"
    for _entry in "${_SKIP_LIST[@]}"; do
      read -r _entry <<< "${_entry}"  # trim whitespace
      if [[ "${_entry,,}" == "${PR_AUTHOR,,}" ]]; then
        _SAFE_AUTHOR="$(_gha_sanitize "${PR_AUTHOR}")"
        echo "::notice::PR #${PR_NUMBER} authored by ${_SAFE_AUTHOR} — skipping review (REVIEW_SKIP_AUTHORS)"

        COMMENT_BODY="Review skipped — PR author **${PR_AUTHOR}** is in the \`REVIEW_SKIP_AUTHORS\` list.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-review check</sub>"

        forge_post_comment "${COMMENT_BODY}" 2>/dev/null || true

        exit 0
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# Deepen shallow clone for git history analysis (risk assessment Tier 2).
# Controlled by REVIEW_GIT_FETCH_DEPTH: "0" = full unshallow, unset = no-op.
# ---------------------------------------------------------------------------
if [[ "${REVIEW_GIT_FETCH_DEPTH:-}" == "0" ]]; then
  _TARGET_DIR="${REPO_DIR:-${GITHUB_WORKSPACE:-.}/target-repo}"
  if [[ ! -d "${_TARGET_DIR}" ]]; then
    echo "::warning::Clone-deepening skipped — target directory '${_TARGET_DIR}' not found"
  elif git -C "${_TARGET_DIR}" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
    echo "Deepening shallow clone for git history analysis..."
    if [[ "${FULLSEND_FORGE}" == "github" && -n "${GH_TOKEN:-}" && -n "${REPO_FULL_NAME:-}" ]]; then
      git -C "${_TARGET_DIR}" fetch --unshallow \
        "https://x-access-token:${GH_TOKEN}@github.com/${REPO_FULL_NAME}.git" 2>/dev/null \
        && echo "Clone deepened successfully" \
        || echo "::warning::Failed to deepen clone — Tier 2 risk signals may be degraded"
    else
      echo "::warning::Cannot deepen clone — missing credentials or unsupported forge"
    fi
  fi
fi

echo "PR #${PR_NUMBER} is open — proceeding with review agent"
