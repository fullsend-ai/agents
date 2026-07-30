#!/usr/bin/env bash
# Adds a pull request to a GitHub merge queue using the GraphQL API.
# Usage: enqueue-pr.sh [PR_NUMBER_OR_URL]
#
# If no argument is given, uses the current branch's PR.
# Requires: gh CLI authenticated with sufficient permissions, and jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/write-approval-check.lib.sh
source "${SCRIPT_DIR}/lib/write-approval-check.lib.sh"

pr="${1:-}"

# Resolve PR to its URL, number, node ID, head commit, and repo in one call
if [[ -z "$pr" ]]; then
  pr_json="$(gh pr view --json url,number,id,headRefOid,headRepository -q '{url,number,id,headRefOid,nwo:.headRepository.owner.login+"/"+.headRepository.name}')"
else
  pr_json="$(gh pr view "$pr" --json url,number,id,headRefOid,headRepository -q '{url,number,id,headRefOid,nwo:.headRepository.owner.login+"/"+.headRepository.name}')"
fi

pr_url="$(echo "$pr_json" | jq -r .url)"
pr_number="$(echo "$pr_json" | jq -r .number)"
pr_node_id="$(echo "$pr_json" | jq -r .id)"
pr_head_sha="$(echo "$pr_json" | jq -r .headRefOid)"
repo_nwo="$(echo "$pr_json" | jq -r .nwo)"

if ! enforce_write_approval_gate "$repo_nwo" "$pr_number" "$pr_head_sha"; then
  echo "Refusing to enqueue $pr_url — see message above." >&2
  exit 1
fi

echo "Enqueuing: $pr_url"

# Enqueue the PR
result="$(gh api graphql -f query='
  mutation($prId: ID!) {
    enqueuePullRequest(input: {pullRequestId: $prId}) {
      mergeQueueEntry {
        position
        estimatedTimeToMerge
      }
    }
  }
' -f prId="$pr_node_id")"

# Check for GraphQL errors
if echo "$result" | jq -e '.errors' >/dev/null 2>&1; then
  echo "GraphQL errors:" >&2
  echo "$result" | jq '.errors' >&2
  exit 1
fi

position="$(echo "$result" | jq -r '.data.enqueuePullRequest.mergeQueueEntry.position')"

if [[ "$position" == "null" ]]; then
  echo "Error: mutation succeeded but mergeQueueEntry is null — the PR may not meet queue requirements." >&2
  exit 1
fi

eta="$(echo "$result" | jq -r '.data.enqueuePullRequest.mergeQueueEntry.estimatedTimeToMerge // "unknown"')"

echo "PR added to merge queue at position $position (ETA: $eta)"
