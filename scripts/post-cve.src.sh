#!/usr/bin/env bash
# post-cve.sh — DRAFT. Validate binding, publish the verdict, label.
#
# Runs on the host after the sandbox is gone. The agent's JSON has already
# passed schema validation (validation_loop). This script is the only thing
# that mutates the tracker (ADR: agents produce, post-scripts act).
#
# POST_CVE_DRY_RUN=1 prints the comment and labels instead of writing them.
#
# When the work item is a branch issue under a parent (lib/cve-fanout.lib.sh),
# the parent's sticky table is rebuilt from its children's labels. GitHub only.
#
# Labels (GitHub/Jira):
#   cve:affected | cve:not-affected | cve:fixed | cve:investigating | cve:failed
#   ready-to-code  only when CVE_AUTO_CODE=on AND status=known_affected AND
#                  remediation.plan_state=ready AND option != rebuild.
#                  The EXISTING code agent then implements the plan.

set -euo pipefail

: "${ISSUE_URL:?}" "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"
DRY_RUN="${POST_CVE_DRY_RUN:-}"   # non-empty: print what would happen, change nothing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/triage-ops.lib.sh
source "${SCRIPT_DIR}/lib/triage-ops.lib.sh"
# shellcheck source=lib/cve-fanout.lib.sh
source "${SCRIPT_DIR}/lib/cve-fanout.lib.sh"
# shellcheck source=lib/jira-auth.lib.sh
source "${SCRIPT_DIR}/lib/jira-auth.lib.sh"
# shellcheck source=lib/cve-receipt.lib.sh
source "${SCRIPT_DIR}/lib/cve-receipt.lib.sh"
[[ "${CVE_BRANCHES_FOLLOW:-}" == "none" ]] && CVE_BRANCHES_FOLLOW=""

# Rebuild the parent's table. Never fails the run: the verdict on this work
# item is already published (or printed) when this is called.
cve_rollup_update() {  # cve_rollup_update REPO ISSUE_NUMBER VULN_ID [DRY]
  local repo="$1" num="$2" id="$3" dry="${4:-}" parent table
  parent=$(cve_parent_of "${repo}" "${num}")
  [[ -n "${parent}" ]] || return 0
  table=$(cve_rollup_body "${repo}" "${parent}" "${id}") || { echo "::warning::cve: could not rebuild the branch table on #${parent}"; return 0; }
  if [[ -n "${dry}" ]]; then
    echo "cve (dry run): would update the branch table marked fullsend-cve-rollup:${id} on #${parent}"
    printf -- '--- branch table ---\n%s\n' "${table}"
    return 0
  fi
  printf '%s' "${table}" | fullsend post-comment --repo "${repo}" --number "${parent}" \
    --marker "fullsend-cve-rollup:${id}" --token "${GH_TOKEN}" --result - \
    || echo "::warning::cve: could not post the branch table on #${parent}"
}

# The validated iteration when the CLI names it; otherwise the last one.
RESULT=""
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  RESULT="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
else
  for dir in iteration-*/output; do
    [[ -f "${dir}/agent-result.json" ]] && RESULT="${dir}/agent-result.json"
  done
fi
[[ -n "${RESULT}" && -f "${RESULT}" ]] || { echo "::error::cve: agent-result.json not found"; exit 1; }

# Binding: the verdict must be about the finding and commit pre-cve staged.
FINDING="${RUNNER_TEMP}/fullsend-cve-stage/cve-finding.json"
[[ -f "${FINDING}" ]] || { echo "::error::cve: staged finding missing at ${FINDING}"; exit 1; }
want_commit=$(jq -r .target.commit "${FINDING}")
want_ref=$(jq -r .target.ref "${FINDING}")
ticket_note=$(jq -r 'if .staged then "ticket text read" else "ticket text not read (" + (.reason // "not staged") + ")" end' \
  "${RUNNER_TEMP}/fullsend-cve-stage/cve-ticket.json" 2>/dev/null || echo "ticket text not read")
want_id=$(jq -r .vulnerability.id "${FINDING}")
got_commit=$(jq -r .bound_commit "${RESULT}")
got_id=$(jq -r .finding_ref "${RESULT}")
if [[ "${got_commit}" != "${want_commit}" || "${got_id}" != "${want_id}" ]]; then
  echo "::error::cve: result is bound to ${got_id}@${got_commit:0:12}, expected ${want_id}@${want_commit:0:12}; discarding"
  exit 1
fi

# pre-cve moves the runner's checkout to the assessed branch for the sandbox.
# Put it back before anything is published: the fullsend CLI reads the Jira
# site from .fullsend/config.yaml in that checkout, and a release branch may
# not have the file.
RESTORE_FILE="${RUNNER_TEMP}/fullsend-cve-stage/restore-commit"
if [[ -f "${RESTORE_FILE}" ]]; then
  restore_commit=$(head -c 64 "${RESTORE_FILE}" | tr -d '[:space:]')
  [[ "${restore_commit}" =~ ^[0-9a-f]{40,64}$ ]] \
    || { echo "::error::cve: the recorded checkout to restore is not a commit id"; exit 1; }
  git -C "${TARGET_REPO_DIR:?}" checkout -q --detach "${restore_commit}" \
    || { echo "::error::cve: could not restore the runner's checkout to ${restore_commit:0:12}; nothing was published"; exit 1; }
fi

status=$(jq -r .status "${RESULT}")
case "${status}" in
  known_affected) label="cve:affected" ;;
  known_not_affected) label="cve:not-affected" ;;
  fixed) label="cve:fixed" ;;
  under_investigation) label="cve:investigating" ;;
  *) label="cve:failed" ;;
esac

promote=""
if [[ "${CVE_AUTO_CODE:-off}" == "on" && "${status}" == "known_affected" ]] \
   && jq -e '.remediation.plan_state == "ready" and .remediation.option != "rebuild"' "${RESULT}" >/dev/null; then
  promote="yes"
fi

body="$(jq -r .comment "${RESULT}")

<sub>cve agent · ${want_id} · branch \`${want_ref}\` · \`${want_commit:0:12}\` · status \`${status}\`$(jq -r 'if .justification then " · " + .justification else "" end' "${RESULT}") · ${ticket_note} · proposed for human review, not a published VEX statement</sub>"

# The receipt is what the code agent's host scripts check before and after
# coding (pre-code-cve, post-code-cve). On GitHub it rides in the comment.
RECEIPT=$(cve_receipt_build "${FINDING}" "${RESULT}" | cve_receipt_valid) \
  || { echo "::error::cve: could not build a valid receipt from the verdict"; exit 1; }
if [[ "${FULLSEND_TRACKER}" != "jira" ]]; then
  body+="
$(cve_receipt_embed "${RECEIPT}")"
fi

if [[ -n "${DRY_RUN}" ]]; then
  echo "cve (dry run): would record the receipt ${RECEIPT}"
  echo "cve (dry run): would post a sticky comment marked fullsend-cve:${want_id} on ${ISSUE_URL}"
  echo "cve (dry run): would set label ${label}${promote:+ and ready-to-code}"
  printf -- '--- comment body ---\n%s\n' "${body}"
  if [[ "${FULLSEND_TRACKER}" == "github" && "${ISSUE_URL}" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/issues/([0-9]+)$ ]]; then
    cve_rollup_update "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${want_id}" dry
  fi
  exit 0
fi

tracker_validate_issue_url
tracker_parse_issue_url
tracker_post_sticky_comment "${body}" "fullsend-cve:${want_id}"
if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
  jira_key="$(basename "${ISSUE_URL}")"
  [[ "${jira_key}" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || { echo "::error::cve: cannot derive the Jira key for the receipt"; exit 1; }
  cve_receipt_write_jira "${jira_key}" "${RECEIPT}" \
    || { echo "::error::cve: the verdict comment was posted but its receipt was not recorded; the code agent will refuse this work item until /fs-cve is run again"; exit 1; }
fi

for l in cve:affected cve:not-affected cve:fixed cve:investigating cve:failed; do
  [[ "${l}" == "${label}" ]] || tracker_remove_label "${l}" 2>/dev/null || true
done
tracker_add_label "${label}"

if [[ -n "${promote}" ]]; then
  tracker_add_label "ready-to-code"
  echo "::notice::cve: promoted to ready-to-code"
fi

if [[ "${FULLSEND_TRACKER}" == "github" ]]; then
  cve_rollup_update "${REPO}" "${ISSUE_NUMBER}" "${want_id}"
fi
