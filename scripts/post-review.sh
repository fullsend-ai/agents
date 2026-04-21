#!/usr/bin/env bash
# Post-script: post the review agent's result to GitHub.
#
# Runs on the GitHub Actions runner AFTER the sandbox is destroyed.
# CWD is runDir.
#
# Required environment variables:
#   REVIEW_TOKEN    — token with pull-requests:write on the target repo
#   PR_NUMBER       — GitHub PR number
#   REPO_FULL_NAME  — owner/repo (e.g. my-org/my-repo)
#
# Exit codes:
#   0 — review posted
#   1 — error (review not posted or fallback comment posted)
set -euo pipefail

: "${REVIEW_TOKEN:?REVIEW_TOKEN is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
if ! [[ "${PR_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "::error::PR_NUMBER must be a positive integer"
  exit 1
fi
: "${REPO_FULL_NAME:?REPO_FULL_NAME is required}"

echo "::add-mask::${REVIEW_TOKEN}"
export GH_TOKEN="${REVIEW_TOKEN}"

# Find the agent result from the last iteration
RESULT_FILE=$(find .  -maxdepth 4 -path '*/iteration-*/output/agent-result.json' | sort -V | tail -1)

if [ -z "${RESULT_FILE}" ] || [ ! -f "${RESULT_FILE}" ]; then
  echo "::error::No agent-result.json found — posting failure notice"
  gh pr comment "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" --body "$(cat <<'EOF'
## Review: automated review

**Outcome:** failure
**Reason:** agent-no-output

The review agent did not produce a result. This PR was NOT reviewed.
Do not count this as an approval.

<sub>Posted by <a href="https://github.com/fullsend-ai/fullsend">fullsend</a> review agent</sub>
EOF
)"
  exit 1
fi

echo "Using result: ${RESULT_FILE}"

ACTION=$(jq -r '.action' "${RESULT_FILE}")

BODY_FILE=$(mktemp)
trap 'rm -f "${BODY_FILE}"' EXIT

case "${ACTION}" in
  approve)          FLAG="--approve" ;;
  request-changes)  FLAG="--request-changes" ;;
  comment)          FLAG="--comment" ;;
  failure)
    REASON=$(jq -r '.reason' "${RESULT_FILE}")
    BODY=$(jq -r '.body // empty' "${RESULT_FILE}")
    if [ -n "${BODY}" ]; then
      printf '%s' "${BODY}" > "${BODY_FILE}"
    else
      cat > "${BODY_FILE}" <<EOF
## Review: automated review

**Outcome:** failure
**Reason:** ${REASON}

This PR was NOT reviewed. Do not count this as an approval.

<sub>Posted by <a href="https://github.com/fullsend-ai/fullsend">fullsend</a> review agent</sub>
EOF
    fi
    gh pr comment "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" --body-file "${BODY_FILE}"
    echo "Review posted: failure notice (${REASON}) on ${REPO_FULL_NAME}#${PR_NUMBER}"
    exit 0
    ;;
  *)
    echo "::error::Unknown action '${ACTION}'"
    exit 1
    ;;
esac

jq -r '.body' "${RESULT_FILE}" > "${BODY_FILE}"
gh pr review "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" "${FLAG}" --body-file "${BODY_FILE}"

echo "Review posted: ${ACTION} on ${REPO_FULL_NAME}#${PR_NUMBER}"
