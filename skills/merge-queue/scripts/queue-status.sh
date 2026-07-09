#!/usr/bin/env bash
# Lists PRs currently in the merge queue for a branch.
# Usage: queue-status.sh [OWNER/REPO] [BRANCH]
#
# Defaults: OWNER/REPO from current gh repo context, BRANCH=main
# Requires: gh CLI authenticated, jq.

set -euo pipefail

repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
branch="${2:-main}"
owner="${repo%%/*}"
name="${repo##*/}"

result="$(gh api graphql -f query='
  query($owner: String!, $name: String!, $branch: String!) {
    repository(owner: $owner, name: $name) {
      mergeQueue(branch: $branch) {
        entries(first: 50) {
          nodes {
            position
            state
            estimatedTimeToMerge
            enqueuedAt
            enqueuer { login }
            pullRequest {
              number
              title
              url
              author { login }
            }
          }
        }
      }
    }
  }
' -f owner="$owner" -f name="$name" -f branch="$branch")"

# Check for GraphQL errors
if echo "$result" | jq -e '.errors' >/dev/null 2>&1; then
  echo "GraphQL errors:" >&2
  echo "$result" | jq '.errors' >&2
  exit 1
fi

count="$(echo "$result" | jq '.data.repository.mergeQueue.entries.nodes | length')"

if [[ "$count" -eq 0 ]]; then
  echo "Merge queue for ${repo}:${branch} is empty."
  exit 0
fi

echo "Merge queue for ${repo}:${branch} — ${count} enqueued:"
echo ""
echo "$result" | jq -r '
  .data.repository.mergeQueue.entries.nodes[] |
  "  #\(.position) [\(.state)] \(.pullRequest.url)  \(.pullRequest.title)\n      by \(.pullRequest.author.login), enqueued \(.enqueuedAt) by \(.enqueuer.login)  ETA: \(.estimatedTimeToMerge // "unknown")s"
'
