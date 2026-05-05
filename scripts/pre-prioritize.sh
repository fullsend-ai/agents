#!/usr/bin/env bash
# pre-prioritize.sh — Select the next issue to RICE-score from the project board.
#
# Runs on the host via the harness pre_script mechanism.
#
# Selection logic:
#   1. Find project items where "RICE Score" field is null → pick first.
#   2. If all scored: find item with oldest "RICE Score" update.
#   3. If oldest is newer than STALE_THRESHOLD → exit 78 (nothing to do).
#   4. Otherwise: export GITHUB_ISSUE_URL for the agent.
#
# Required env vars:
#   GH_TOKEN         — GitHub token with project read scope
#   ORG              — GitHub organization
#   PROJECT_NUMBER   — Project board number
#
# Optional env vars:
#   STALE_THRESHOLD  — Re-score items older than this (default: 7d).
#                      Supports: Nd (days), Nh (hours).

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${ORG:?ORG must be set}"
: "${PROJECT_NUMBER:?PROJECT_NUMBER must be set}"

STALE_THRESHOLD="${STALE_THRESHOLD:-7d}"

# Parse threshold into seconds.
parse_threshold() {
  local val="${1%[dh]}"
  local unit="${1: -1}"
  case "${unit}" in
    d) echo $(( val * 86400 )) ;;
    h) echo $(( val * 3600 )) ;;
    *) echo "ERROR: unsupported threshold unit '${unit}' (use Nd or Nh)" >&2; exit 1 ;;
  esac
}
THRESHOLD_SECONDS=$(parse_threshold "${STALE_THRESHOLD}")

# Fetch all project items with their RICE Score field and content URL.
# We use the GraphQL API because gh project item-list does not expose
# custom field values reliably.
PROJECT_ID=$(gh project view "${PROJECT_NUMBER}" --owner "${ORG}" --format json | jq -r '.id')

# Get the RICE Score field ID.
SCORE_FIELD_ID=$(gh project field-list "${PROJECT_NUMBER}" --owner "${ORG}" --format json \
  | jq -r '.fields[] | select(.name == "RICE Score") | .id')

if [[ -z "${SCORE_FIELD_ID}" ]]; then
  echo "ERROR: 'RICE Score' field not found on project ${PROJECT_NUMBER}."
  echo "Run scripts/setup-prioritize.sh first."
  exit 1
fi

# Fetch items via GraphQL to get field values.
# Paginate through all items using cursor-based pagination.
ITEMS_JSON='{"data":{"node":{"items":{"nodes":[]}}}}'
HAS_NEXT_PAGE=true
CURSOR=""

while [[ "${HAS_NEXT_PAGE}" == "true" ]]; do
  if [[ -z "${CURSOR}" ]]; then
    AFTER_ARG=""
  else
    AFTER_ARG=", after: \$cursor"
  fi

  PAGE_JSON=$(gh api graphql -f query="
    query(\$projectId: ID!$([ -n "${CURSOR}" ] && echo ', $cursor: String!')) {
      node(id: \$projectId) {
        ... on ProjectV2 {
          items(first: 100${AFTER_ARG}) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              id
              fieldValues(first: 20) {
                nodes {
                  ... on ProjectV2ItemFieldNumberValue {
                    field { ... on ProjectV2Field { id name } }
                    number
                    updatedAt
                  }
                }
              }
              content {
                ... on Issue {
                  url
                  state
                }
              }
            }
          }
        }
      }
    }
  " -f projectId="${PROJECT_ID}" ${CURSOR:+-f cursor="${CURSOR}"})

  # Merge nodes from this page into the accumulated result.
  ITEMS_JSON=$(jq -s '
    .[0].data.node.items.nodes += .[1].data.node.items.nodes
    | .[0]
  ' <(echo "${ITEMS_JSON}") <(echo "${PAGE_JSON}"))

  HAS_NEXT_PAGE=$(echo "${PAGE_JSON}" | jq -r '.data.node.items.pageInfo.hasNextPage')
  CURSOR=$(echo "${PAGE_JSON}" | jq -r '.data.node.items.pageInfo.endCursor')
done

echo "Fetched $(echo "${ITEMS_JSON}" | jq '.data.node.items.nodes | length') project items."

# Find the first open issue with no RICE Score.
UNSCORED_URL=$(echo "${ITEMS_JSON}" | jq -r --arg fid "${SCORE_FIELD_ID}" '
  [.data.node.items.nodes[]
   | select(.content.state == "OPEN")
   | select(
       [.fieldValues.nodes[]
        | select(.field.id == $fid)
       ] | length == 0
     )
   | .content.url
  ] | first // empty
')

if [[ -n "${UNSCORED_URL}" && "${UNSCORED_URL}" != "null" ]]; then
  echo "Found unscored issue: ${UNSCORED_URL}"
  echo "GITHUB_ISSUE_URL=${UNSCORED_URL}" >> "${GITHUB_ENV:-/dev/null}"
  # Write env file for sandbox and post-script consumption.
  # The fullsend binary does not propagate pre-script exports, so this
  # file-based workaround is necessary. See note 8 in the plan.
  echo "export GITHUB_ISSUE_URL=\"${UNSCORED_URL}\"" > /tmp/pre-prioritize-output.env
  export GITHUB_ISSUE_URL="${UNSCORED_URL}"
  exit 0
fi

echo "All issues are scored. Checking for stale scores..."

# Find the item with the oldest RICE Score update.
OLDEST=$(echo "${ITEMS_JSON}" | jq -r --arg fid "${SCORE_FIELD_ID}" '
  [.data.node.items.nodes[]
   | select(.content.state == "OPEN")
   | {
       url: .content.url,
       updatedAt: ([.fieldValues.nodes[] | select(.field.id == $fid) | .updatedAt] | first)
     }
   | select(.updatedAt != null)
  ]
  | sort_by(.updatedAt)
  | if length == 0 then empty else first | "\(.updatedAt)\t\(.url)" end
')

if [[ -z "${OLDEST}" || "${OLDEST}" == "null" ]]; then
  echo "No scored items found. Nothing to do."
  exit 78
fi

OLDEST_DATE=$(echo "${OLDEST}" | cut -f1)
OLDEST_URL=$(echo "${OLDEST}" | cut -f2)

# Check staleness.
OLDEST_EPOCH=$(date -d "${OLDEST_DATE}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${OLDEST_DATE}" +%s 2>/dev/null)
NOW_EPOCH=$(date +%s)
AGE_SECONDS=$(( NOW_EPOCH - OLDEST_EPOCH ))

if [[ ${AGE_SECONDS} -lt ${THRESHOLD_SECONDS} ]]; then
  echo "Oldest score is $(( AGE_SECONDS / 3600 ))h old (threshold: ${STALE_THRESHOLD}). Nothing to do."
  exit 78
fi

echo "Found stale score ($(( AGE_SECONDS / 86400 ))d old): ${OLDEST_URL}"
echo "GITHUB_ISSUE_URL=${OLDEST_URL}" >> "${GITHUB_ENV:-/dev/null}"
echo "export GITHUB_ISSUE_URL=\"${OLDEST_URL}\"" > /tmp/pre-prioritize-output.env
export GITHUB_ISSUE_URL="${OLDEST_URL}"
exit 0
