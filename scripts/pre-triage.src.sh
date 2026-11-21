#!/usr/bin/env bash
# pre-triage.sh — Strip triage-related labels before the agent runs.
#
# Runs on the host via the harness pre_script mechanism. Ensures every
# triage invocation starts from a clean label baseline, preventing
# mutual-exclusion violations (Story 2, #125).
#
# An issue that carries a skip label (skip-triage, or one listed in
# TRIAGE_SKIP_LABELS) is skipped through the pre-script output protocol
# (fullsend docs/normative/prescript-output/v1) before any label changes,
# unless TRIAGE_SKIP_LABEL_OVERRIDE is "true" (#2076).
#
# Required env vars:
#   ISSUE_URL        — HTML URL of the issue
#   FULLSEND_TRACKER — "github", "gitlab", or "jira" (falls back to FULLSEND_FORGE)
#
# Optional env vars:
#   TRIAGE_SKIP_LABELS          — comma-separated extra skip labels
#   TRIAGE_SKIP_LABEL_OVERRIDE  — "true" for a human /fs-triage request
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
# shellcheck source=lib/prescript-output.lib.sh
source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"
# shellcheck source=lib/triage-ops.lib.sh
source "${SCRIPT_DIR}/lib/triage-ops.lib.sh"

tracker_validate_issue_url
echo "::notice::🔗 Triage target: $(_gha_sanitize "${ISSUE_URL}")"
tracker_parse_issue_url

# Skip labels (#2076): skip-triage, or a label listed in TRIAGE_SKIP_LABELS,
# keeps the issue with a planning process. Skip before the label reset so a
# skipped run changes no labels and posts no comment. A human /fs-triage
# overrides the skip: harness/triage.yaml sets TRIAGE_SKIP_LABEL_OVERRIDE for
# that event.
if [[ "${TRIAGE_SKIP_LABEL_OVERRIDE:-}" == "true" ]]; then
  echo "Human /fs-triage request — skip labels do not apply"
else
  skip_rc=0
  SKIP_LABEL="$(triage_find_skip_label)" || skip_rc=$?
  if [[ "${skip_rc}" -eq 0 ]]; then
    SAFE_SKIP_LABEL="$(_gha_sanitize "${SKIP_LABEL}")"
    echo "::notice::Issue carries skip label '${SAFE_SKIP_LABEL}' — skipping triage"
    prescript_output "skipped" "true"
    prescript_output "reason" "issue carries skip label '${SAFE_SKIP_LABEL}'; comment /fs-triage to triage it anyway"
    exit 0
  elif [[ "${skip_rc}" -ne 1 ]]; then
    echo "::error::Cannot read the issue labels to check for skip labels" >&2
    exit 1
  fi
fi

echo "Resetting triage labels on ${REPO}#${ISSUE_NUMBER}"

TRIAGE_LABELS=(needs-info ready-to-code duplicate feature question not-planned completed pr-open)

tracker_strip_labels "${TRIAGE_LABELS[@]}"
tracker_verify_labels_stripped "${TRIAGE_LABELS[@]}"

echo "Label reset complete."
