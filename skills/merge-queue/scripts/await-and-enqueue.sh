#!/usr/bin/env bash
# Waits for a PR's required checks and approvals, then enqueues it.
# Exits early if any required check fails.
#
# Usage: await-and-enqueue.sh [PR_NUMBER_OR_URL]
#
# If no argument is given, uses the current branch's PR.
# Polls every 30 seconds. Requires: gh CLI, jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/write-approval-check.lib.sh
source "${SCRIPT_DIR}/lib/write-approval-check.lib.sh"

POLL_INTERVAL="${POLL_INTERVAL:-30}"
pr="${1:-}"

# Resolve PR URL, number, repo, and base branch
if [[ -z "$pr" ]]; then
  pr_json_init="$(gh pr view --json url,number,baseRefName,headRepository -q '{url,number,baseRefName,nwo:.headRepository.owner.login+"/"+.headRepository.name}')"
else
  pr_json_init="$(gh pr view "$pr" --json url,number,baseRefName,headRepository -q '{url,number,baseRefName,nwo:.headRepository.owner.login+"/"+.headRepository.name}')"
fi

pr_url="$(echo "$pr_json_init" | jq -r .url)"
pr_number="$(echo "$pr_json_init" | jq -r .number)"
base_branch="$(echo "$pr_json_init" | jq -r .baseRefName)"
repo_nwo="$(echo "$pr_json_init" | jq -r .nwo)"

# fullsend-ai/fullsend#5687: whether this PR ever required write-approval
# (per the immutable issue-events timeline, not current label state — see
# lib/write-approval-check.lib.sh) does not change over the life of the PR,
# so resolve it once rather than on every poll.
ever_required_write_approval="$(write_approval_ever_required "$repo_nwo" "$pr_number")"

# Fetch required status checks from branch rulesets (fail-closed on error).
# Note: only the rulesets API is queried. Repositories using classic branch
# protection rules (without rulesets) will not have their required checks
# discovered, and the script will proceed based on reported check statuses only.
if ! required_json="$(gh api "repos/$repo_nwo/rules/branches/$base_branch" \
  --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | unique' 2>&1)"; then
  echo "Error: failed to fetch required checks for $repo_nwo branch $base_branch" >&2
  echo "$required_json" >&2
  exit 1
fi

if [[ "$(echo "$required_json" | jq 'length')" -gt 0 ]]; then
  echo "Required checks: $(echo "$required_json" | jq -r 'join(", ")')"
fi

echo "Waiting for checks and approvals on: $pr_url"

while true; do
  # Get check rollup, review decision, and current head commit in one call
  pr_json="$(gh pr view "$pr_url" --json statusCheckRollup,reviewDecision,headRefOid)"

  review_decision="$(echo "$pr_json" | jq -r '.reviewDecision // "NONE"')"
  head_sha="$(echo "$pr_json" | jq -r '.headRefOid')"

  # Use jq to analyze all check statuses and required check coverage in one pass
  result="$(echo "$pr_json" | jq -r --argjson required "$required_json" '
    .statusCheckRollup as $checks |
    # Build map of check name -> conclusion.
    # statusCheckRollup contains both CheckRun (.name, .conclusion) and
    # StatusContext (.context, .state) objects — handle both.
    ($checks | map({((.name // .context // "unknown")): (.conclusion // .state // .status // "PENDING")}) | add // {}) as $map |
    # Check for failures (case-insensitive: StatusContext .state may be lowercase)
    [$map | to_entries[] | select(.value | test("FAILURE|ERROR|CANCELLED|TIMED_OUT|STARTUP_FAILURE|ACTION_REQUIRED|STALE"; "i")) | .key + " (" + .value + ")"] as $failures |
    # Check for pending (case-insensitive for the same reason)
    [$map | to_entries[] | select(.value | test("SUCCESS|NEUTRAL|SKIPPED|COMPLETED|FAILURE|ERROR|CANCELLED|TIMED_OUT|STARTUP_FAILURE|ACTION_REQUIRED|STALE"; "i") | not) | .key] as $pending |
    # Check for missing required checks
    [$required[] | select(. as $r | $map | has($r) | not)] as $missing |
    {failures: $failures, pending: $pending, missing: $missing}
  ')"

  failures="$(echo "$result" | jq -r '.failures[]' 2>/dev/null || true)"
  pending="$(echo "$result" | jq -r '.pending[]' 2>/dev/null || true)"
  missing="$(echo "$result" | jq -r '.missing[]' 2>/dev/null || true)"

  if [[ -n "$failures" ]]; then
    echo "$failures" | while IFS= read -r f; do echo "FAILED: $f"; done
    echo "Aborting — one or more required checks failed."
    exit 1
  fi

  has_pending=false
  if [[ -n "$pending" ]]; then
    has_pending=true
  fi
  if [[ -n "$missing" ]]; then
    echo "$missing" | while IFS= read -r m; do echo "Required check not yet reported: $m"; done
    has_pending=true
  fi

  if [[ "$has_pending" == "true" ]]; then
    echo "Waiting ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
    continue
  fi

  if [[ "$review_decision" != "APPROVED" ]]; then
    echo "Checks passed but review not yet approved (status: $review_decision)... waiting ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    continue
  fi

  if [[ "$ever_required_write_approval" == "true" ]] && ! has_write_plus_approval "$repo_nwo" "$pr_number" "$head_sha"; then
    echo "PR required needs-write-approval at some point but has no APPROVE review, on the current head commit, from a currently admin/maintain/write collaborator — waiting ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    continue
  fi

  echo "All checks passed and PR is approved. Enqueuing..."
  break
done

# Delegate to the enqueue script, which independently re-verifies the
# write-approval gate at the actual enqueue call site.
exec bash "$SCRIPT_DIR/enqueue-pr.sh" "$pr_url"
