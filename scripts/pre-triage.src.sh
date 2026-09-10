#!/usr/bin/env bash
# pre-triage.sh — Strip triage-related labels before the agent runs.
#
# Runs on the host via the harness pre_script mechanism. Ensures every
# triage invocation starts from a clean label baseline, preventing
# mutual-exclusion violations (Story 2, #125).
#
# Required env vars:
#   ISSUE_URL        — HTML URL of the issue
#   FULLSEND_TRACKER — "github", "gitlab", or "jira" (falls back to FULLSEND_FORGE)
#
# IMPORTANT: Uses the labels API directly (DELETE /issues/{number}/labels/{name})
# instead of gh issue edit. gh issue edit uses PATCH /issues/{number}
# which fires issues.edited, re-triggering the triage dispatch in the shim workflow.

set -euo pipefail

: "${ISSUE_URL:?ISSUE_URL must be set}"
FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"
: "${FULLSEND_TRACKER:?FULLSEND_TRACKER must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/triage-ops.lib.sh
source "${SCRIPT_DIR}/lib/triage-ops.lib.sh"

tracker_validate_issue_url
echo "::notice::🔗 Triage target: $(_gha_sanitize "${ISSUE_URL}")"
tracker_parse_issue_url

echo "Resetting triage labels on ${REPO}#${ISSUE_NUMBER}"

TRIAGE_LABELS=(needs-info ready-to-code duplicate feature question not-planned pr-open)

tracker_strip_labels "${TRIAGE_LABELS[@]}"
tracker_verify_labels_stripped "${TRIAGE_LABELS[@]}"

echo "Label reset complete."
