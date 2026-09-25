#!/usr/bin/env bash
# pre-triage.sh — Validate the triage target before the agent runs.
#
# Runs on the host via the harness pre_script mechanism. Control-label
# reconciliation is owned by post-triage.sh, which diffs the desired
# labels against the issue's current labels so unchanged labels are not
# removed and re-added (#1408).
#
# Trade-off: this script no longer strips control labels up front, so the
# mutual-exclusion guarantee (preventing conflicting control labels,
# Story 2, #125) now only holds after a *successful* post-triage.sh run
# reaches its stale-label reconciliation loop. An early exit in
# post-triage.sh (e.g. invalid agent JSON) no longer guarantees stale
# control labels are cleared before the next attempt.
#
# Required env vars:
#   ISSUE_URL        — HTML URL of the issue
#   FULLSEND_TRACKER — "github", "gitlab", or "jira" (falls back to FULLSEND_FORGE)

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

echo "Triage target validated: ${REPO}#${ISSUE_NUMBER}"
