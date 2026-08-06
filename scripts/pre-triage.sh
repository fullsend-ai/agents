#!/usr/bin/env bash
# pre-triage.sh — Strip triage-related labels before the agent runs.
#
# Runs on the host via the harness pre_script mechanism. Ensures every
# triage invocation starts from a clean label baseline, preventing
# mutual-exclusion violations (Story 2, #125).
#
# Required env vars:
#   ISSUE_URL      — HTML URL of the issue
#   FULLSEND_FORGE — "github" or "gitlab"
#
# IMPORTANT: Uses the labels API directly (DELETE /issues/{number}/labels/{name})
# instead of gh issue edit. gh issue edit uses PATCH /issues/{number}
# which fires issues.edited, re-triggering the triage dispatch in the shim workflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/${FULLSEND_FORGE}/triage-ops.sh"

echo "::notice::🔗 Triage target: ${ISSUE_URL}"

forge_validate_issue_url
forge_parse_issue_url

echo "Resetting triage labels on ${REPO}#${ISSUE_NUMBER}"

TRIAGE_LABELS=(needs-info ready-to-code duplicate feature question not-planned pr-open)

forge_strip_labels "${TRIAGE_LABELS[@]}"
forge_verify_labels_stripped "${TRIAGE_LABELS[@]}"

echo "Label reset complete."
