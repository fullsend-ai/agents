#!/usr/bin/env bash
# pre-code-cve.sh — DRAFT. Host gate in front of the code agent for a work
# item labelled `cve`. Selected by an overlay in harness/code.yaml; runs on
# the runner before the sandbox exists, then hands over to the ordinary
# pre-script.
#
# The code agent's trigger already requires the `cve:affected` label. A label
# says a verdict existed once. This gate checks the verdict itself:
#   1. a valid receipt exists for this work item (lib/cve-receipt.lib.sh);
#   2. it is for this repository, says known_affected, and carries a ready
#      plan the code agent is allowed to execute (not a rebuild);
#   3. it is still current: the assessed branch is at the assessed commit, or
#      nothing the plan depends on has changed since (the plan's change paths
#      and any dependency manifest or lockfile).
# Any failure skips the run with the reason. Nothing is widened: the receipt
# can stop a run or narrow it, never authorize more.
#
# Required env: ISSUE_URL, REPO_FULL_NAME, TARGET_REPO_DIR; GH_TOKEN (GitHub
#   work item) or JIRA_BASE_URL + JIRA_TOKEN [+ JIRA_USER_EMAIL] (Jira).

set -euo pipefail

: "${ISSUE_URL:?ISSUE_URL must be set}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME must be set}"
: "${TARGET_REPO_DIR:?TARGET_REPO_DIR must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prescript-output.lib.sh
source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"
# shellcheck source=lib/jira-auth.lib.sh
source "${SCRIPT_DIR}/lib/jira-auth.lib.sh"
# shellcheck source=lib/cve-receipt.lib.sh
source "${SCRIPT_DIR}/lib/cve-receipt.lib.sh"
# shellcheck source=lib/cve-git.lib.sh
source "${SCRIPT_DIR}/lib/cve-git.lib.sh"

STAGE="$(cve_receipt_staging_dir)"
rm -rf "${STAGE}"

stop() {
  echo "::warning::cve code gate: not coding — $1"
  prescript_output skipped true
  prescript_output reason "cve code gate: $1"
  exit 0
}

# --- 1. Read the receipt from the work item's own tracker --------------------
NEXT="pre-code.sh"
if [[ "${ISSUE_URL}" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/issues/([0-9]+)$ ]]; then
  RECEIPT=$(cve_receipt_read_github "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}") \
    || { echo "::error::cve code gate: could not read the work item's comments"; exit 1; }
elif [[ "${ISSUE_URL}" =~ /browse/([A-Z][A-Z0-9]+-[0-9]+)$ ]]; then
  NEXT="pre-code-jira.sh"
  : "${JIRA_BASE_URL:?JIRA_BASE_URL must be set for a Jira work item}" "${JIRA_TOKEN:?JIRA_TOKEN must be set for a Jira work item}"
  RECEIPT=$(cve_receipt_read_jira "${BASH_REMATCH[1]}") \
    || { echo "::error::cve code gate: could not read the Jira issue property"; exit 1; }
else
  stop "the work item's tracker is not supported"
fi
[[ -n "${RECEIPT}" ]] || stop "no cve verdict is recorded on this work item; run /fs-cve first"
field() { jq -r "$1" <<<"${RECEIPT}"; }

# --- 2. Is it a plan the code agent may execute? -----------------------------
[[ "$(field .repository)" == "${REPO_FULL_NAME}" ]] \
  || stop "the verdict is for $(field .repository), not this repository"
[[ "$(field .status)" == "known_affected" ]] \
  || stop "the latest verdict is $(field .status), not known_affected"
[[ "$(field .plan_state)" == "ready" ]] \
  || stop "the remediation plan is not ready"
[[ "$(field .option)" != "rebuild" && -n "$(field .option)" ]] \
  || stop "the plan is a rebuild, which needs a build handoff and no code change"
[[ "$(jq '.change_paths | length' <<<"${RECEIPT}")" -gt 0 ]] \
  || stop "the plan names no files to change"

# --- 3. Is it still current? --------------------------------------------------
REF="$(field .ref)"; COMMIT="$(field .commit)"
# The runner's checkout is the default branch, one commit deep. Comparing the
# assessed commit with the branch as it is now needs the branch and every
# commit between the two, so fetch them when any of that is missing.
if cve_git_is_shallow "${TARGET_REPO_DIR}" \
   || ! git -C "${TARGET_REPO_DIR}" cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
   || ! cve_git_branch_commit "${TARGET_REPO_DIR}" "${REF}" >/dev/null; then
  cve_git_fetch_history "${TARGET_REPO_DIR}" "${REF}" || true
fi
HEAD_NOW=$(cve_git_branch_commit "${TARGET_REPO_DIR}" "${REF}") \
  || stop "branch ${REF} could not be fetched, or no longer exists; run /fs-cve again"
git -C "${TARGET_REPO_DIR}" cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
  || stop "the assessed commit ${COMMIT:0:12} is not on branch ${REF} any more; run /fs-cve again"
if [[ "${HEAD_NOW}" != "${COMMIT}" ]]; then
  git -C "${TARGET_REPO_DIR}" merge-base --is-ancestor "${COMMIT}" "${HEAD_NOW}" \
    || stop "branch ${REF} was rewritten since the assessment; run /fs-cve again"
  mapfile -t PLAN_PATHS < <(jq -r '.change_paths[]' <<<"${RECEIPT}")
  MANIFESTS=(':(glob)**/requirements*.txt' ':(glob)**/*.lock' ':(glob)**/go.mod' ':(glob)**/go.sum'
    ':(glob)**/package.json' ':(glob)**/package-lock.json' ':(glob)**/pnpm-lock.yaml'
    ':(glob)**/Pipfile' ':(glob)**/pyproject.toml' ':(glob)**/Cargo.toml' ':(glob)**/pom.xml'
    ':(glob)**/build.gradle*' ':(glob)**/Gemfile')
  CHANGED=$(git -C "${TARGET_REPO_DIR}" diff --name-only "${COMMIT}" "${HEAD_NOW}" -- "${PLAN_PATHS[@]}" "${MANIFESTS[@]}")
  if [[ -n "${CHANGED}" ]]; then
    stop "the verdict is stale: since ${COMMIT:0:12}, branch ${REF} changed $(wc -l <<<"${CHANGED}" | tr -d ' ') file(s) the plan depends on (first: $(sed -n 1p <<<"${CHANGED}")); run /fs-cve again"
  fi
  echo "::notice::cve code gate: ${REF} moved from ${COMMIT:0:12} to ${HEAD_NOW:0:12}; nothing the plan depends on changed"
fi

# --- 4. Admit, and leave the receipt for post-code-cve ------------------------
mkdir -p "${STAGE}"
printf '%s\n' "${RECEIPT}" > "${STAGE}/receipt.json"
echo "::notice::cve code gate: admitted $(field .id) on ${REF} ($(field .option), $(jq '.change_paths | length' <<<"${RECEIPT}") path(s))"
exec bash "${SCRIPT_DIR}/${NEXT}" "$@"
