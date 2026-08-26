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
# When REVIEW_GIT_FETCH_DEPTH is unset, default to "0" if risk assessment is
# enabled — the Tier 2 sub-agent needs commit history, not just the tip.
# Explicit values always take precedence.
#
# The deepen is blobless (--filter=blob:none): Tier 2 reads commit and tree
# metadata only, so fetching historical file contents would be pure cost.
# The filter is only honoured for a configured remote — with a bare URL git
# accepts the flag and silently fetches everything — hence "origin", which
# actions/checkout configures as the target repo's HTTPS URL.
# ---------------------------------------------------------------------------
if [[ -z "${REVIEW_GIT_FETCH_DEPTH+set}" && "${REVIEW_RISK_ASSESSMENT_ENABLED:-false}" == "true" ]]; then
  REVIEW_GIT_FETCH_DEPTH="0"
fi
if [[ "${REVIEW_GIT_FETCH_DEPTH:-}" == "0" ]]; then
  _TARGET_DIR="${REPO_DIR:-${GITHUB_WORKSPACE:-.}/target-repo}"
  if [[ ! -d "${_TARGET_DIR}" ]]; then
    echo "::warning::Clone-deepening skipped — target directory '${_TARGET_DIR}' not found"
  elif git -C "${_TARGET_DIR}" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
    echo "Deepening shallow clone for git history analysis..."
    if [[ "${FULLSEND_FORGE}" != "github" || -z "${GH_TOKEN:-}" || -z "${REPO_FULL_NAME:-}" ]]; then
      echo "::warning::Cannot deepen clone — missing credentials or unsupported forge"
    elif ! command -v timeout >/dev/null 2>&1; then
      # Local runs on macOS need coreutils for GNU timeout; without a bound
      # this fetch is exactly the unbounded cost #1032 was filed about.
      echo "::warning::Cannot deepen clone — 'timeout' not found (install coreutils); Tier 2 risk signals may be degraded"
    elif timeout --kill-after=5 120 git -C "${_TARGET_DIR}" \
        -c "http.extraheader=Authorization: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 -w0)" \
        fetch --unshallow --filter=blob:none origin 2>/dev/null; then
      # A blobless clone records origin as a promisor remote, so git tries to
      # lazily fetch any blob it needs. Inside the review sandbox that fetch
      # can never succeed — the egress policy allows the GitHub REST API, not
      # the git wire protocol — so it blocks until the run's timeout. Rename
      # detection is the one thing in the Tier 2 command set that reads blob
      # content (git show/diff-tree on a commit containing a rename), so turn
      # it off repo-locally. Every Tier 2 command is then blob-free, and the
      # coupling signal is unaffected: a rename reported as delete+add still
      # names both paths.
      # Guarded: under `set -e` a failed config write would abort the whole
      # pre-script, turning a degraded risk signal into a failed review.
      if git -C "${_TARGET_DIR}" config diff.renames false; then
        echo "Clone deepened successfully (blobless; rename detection disabled)"
      else
        echo "::warning::Deepened clone but could not disable rename detection — Tier 2 history commands may block on unavailable blobs"
      fi
    else
      # A killed or failed fetch leaves the clone shallow, which the Tier 2
      # sub-agent detects on its own and treats as an unavailable tier.
      echo "::warning::Failed to deepen clone — Tier 2 risk signals may be degraded"
    fi
  fi
fi

echo "PR #${PR_NUMBER} is open — proceeding with review agent"
