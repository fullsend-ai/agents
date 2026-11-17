#!/usr/bin/env bash
# pre-triage.sh — Strip triage-related labels before the agent runs.
#
# Runs on the host via the harness pre_script mechanism. Ensures every
# triage invocation starts from a clean label baseline, preventing
# mutual-exclusion violations (Story 2, #125), and, when RUNNER_TEMP is
# set, writes step 2e's prior triage analysis (prior-triage.lib.sh).
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
# shellcheck source=lib/prior-triage.lib.sh
source "${SCRIPT_DIR}/lib/prior-triage.lib.sh"

tracker_validate_issue_url
echo "::notice::🔗 Triage target: $(_gha_sanitize "${ISSUE_URL}")"
tracker_parse_issue_url

echo "Resetting triage labels on ${REPO}#${ISSUE_NUMBER}"

TRIAGE_LABELS=(needs-info ready-to-code duplicate feature question not-planned completed pr-open)

tracker_strip_labels "${TRIAGE_LABELS[@]}"
tracker_verify_labels_stripped "${TRIAGE_LABELS[@]}"

echo "Label reset complete."

# Step 2e's prior analysis, read here on the host and copied into the
# sandbox by the optional host file in harness/triage.yaml, whose src must
# stay this path. GitHub Actions gives each job its own RUNNER_TEMP;
# fullsend's GitLab job script defaults it to /tmp, shared by the jobs of a
# persistent runner, so the path carries CI_JOB_ID. On GitHub it is unset
# and the host file expands it to empty too, so the directory there is
# triage-workspace- with a trailing dash. Tracker errors only warn; a job
# directory another user could control fails the run (prior-triage.lib.sh).
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  prior_triage_write "${RUNNER_TEMP}/triage-workspace-${CI_JOB_ID:-}/prior-triage.json"
fi
