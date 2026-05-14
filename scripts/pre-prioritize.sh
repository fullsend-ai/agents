#!/usr/bin/env bash
# pre-prioritize.sh — Validate the issue URL before the agent runs.
#
# Runs on the host via the harness pre_script mechanism.
#
# Required env vars:
#   GITHUB_ISSUE_URL — HTML URL of the issue to score
#   GH_TOKEN         — GitHub token with project read scope

set -euo pipefail

echo "::notice::🔗 Prioritize target: ${GITHUB_ISSUE_URL}"

if [[ ! "${GITHUB_ISSUE_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
  echo "ERROR: GITHUB_ISSUE_URL does not match expected pattern: ${GITHUB_ISSUE_URL}"
  exit 1
fi

echo "Issue URL validated."
