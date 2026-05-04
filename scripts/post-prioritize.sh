#!/usr/bin/env bash
# post-prioritize.sh — Write RICE scores to the project board and post a reasoning comment.
#
# Runs on the host after sandbox cleanup. Working directory is the fullsend
# run output directory (e.g., /tmp/fullsend/agent-prioritize-<id>/).
#
# Required env vars:
#   GITHUB_ISSUE_URL  — HTML URL of the issue
#   GH_TOKEN          — GitHub token with project write + issues write scope
#   ORG               — GitHub organization
#   PROJECT_NUMBER    — Project board number

set -euo pipefail

# Read issue URL from pre-script output (fullsend doesn't propagate
# pre-script env exports to the post-script process).
# Reads the value directly instead of sourcing to avoid executing arbitrary shell.
if [[ -f /tmp/pre-prioritize-output.env ]]; then
  GITHUB_ISSUE_URL=$(grep -oP '(?<=GITHUB_ISSUE_URL=")[^"]+' /tmp/pre-prioritize-output.env || true)
  export GITHUB_ISSUE_URL
fi

: "${GITHUB_ISSUE_URL:?GITHUB_ISSUE_URL must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${ORG:?ORG must be set}"
: "${PROJECT_NUMBER:?PROJECT_NUMBER must be set}"

# Validate URL format early, before any parsing or API calls.
if [[ ! "${GITHUB_ISSUE_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
  echo "ERROR: GITHUB_ISSUE_URL does not match expected pattern: ${GITHUB_ISSUE_URL}"
  exit 1
fi

# Find the result JSON from the last iteration.
RESULT_FILE=""
for dir in iteration-*/output; do
  if [[ -f "${dir}/agent-result.json" ]]; then
    RESULT_FILE="${dir}/agent-result.json"
  fi
done

if [[ -z "${RESULT_FILE}" ]]; then
  echo "ERROR: agent-result.json not found in any iteration output directory"
  exit 1
fi

echo "Reading RICE result from: ${RESULT_FILE}"

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

# Extract scores.
REACH=$(jq -r '.reach' "${RESULT_FILE}")
IMPACT=$(jq -r '.impact' "${RESULT_FILE}")
CONFIDENCE=$(jq -r '.confidence' "${RESULT_FILE}")
EFFORT=$(jq -r '.effort' "${RESULT_FILE}")

# Compute final RICE score: (R * I * C) / E
SCORE=$(jq -n --argjson r "${REACH}" --argjson i "${IMPACT}" \
  --argjson c "${CONFIDENCE}" --argjson e "${EFFORT}" \
  '(($r * $i * $c / $e) * 100 | round) / 100')

echo "RICE scores: R=${REACH} I=${IMPACT} C=${CONFIDENCE} E=${EFFORT} → Score=${SCORE}"

# Extract reasoning (escape pipe chars to avoid breaking the markdown table).
REASONING_REACH=$(jq -r '.reasoning.reach' "${RESULT_FILE}" | sed 's/|/\\|/g')
REASONING_IMPACT=$(jq -r '.reasoning.impact' "${RESULT_FILE}" | sed 's/|/\\|/g')
REASONING_CONFIDENCE=$(jq -r '.reasoning.confidence' "${RESULT_FILE}" | sed 's/|/\\|/g')
REASONING_EFFORT=$(jq -r '.reasoning.effort' "${RESULT_FILE}" | sed 's/|/\\|/g')

# --- Write scores to the project board ---

# Resolve project and item IDs.
PROJECT_ID=$(gh project view "${PROJECT_NUMBER}" --owner "${ORG}" --format json | jq -r '.id')

# Parse repo and issue number from URL.
REPO=$(echo "${GITHUB_ISSUE_URL}" | sed 's|https://github.com/||; s|/issues/.*||')
ISSUE_NUMBER=$(basename "${GITHUB_ISSUE_URL}")

# Find the project item ID for this issue.
ITEMS_RESPONSE=$(gh api graphql -f query='
  query($projectId: ID!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        items(first: 100) {
          nodes {
            id
            content { ... on Issue { url } }
          }
        }
      }
    }
  }
' -f projectId="${PROJECT_ID}")

# Warn if we hit the pagination limit.
ITEM_COUNT=$(echo "${ITEMS_RESPONSE}" | jq '[.data.node.items.nodes[]] | length')
if [[ "${ITEM_COUNT}" -ge 100 ]]; then
  echo "WARNING: project board has ${ITEM_COUNT}+ items; pagination limit is 100. Issue may not be found."
fi

ITEM_ID=$(echo "${ITEMS_RESPONSE}" | jq -r --arg url "${GITHUB_ISSUE_URL}" \
    '.data.node.items.nodes[] | select(.content.url == $url) | .id')

if [[ -z "${ITEM_ID}" || "${ITEM_ID}" == "null" ]]; then
  echo "ERROR: issue ${GITHUB_ISSUE_URL} not found on project board"
  exit 1
fi

# Get field IDs for all RICE fields.
FIELDS_JSON=$(gh project field-list "${PROJECT_NUMBER}" --owner "${ORG}" --format json)

get_field_id() {
  echo "${FIELDS_JSON}" | jq -r --arg name "$1" '.fields[] | select(.name == $name) | .id'
}

REACH_FIELD_ID=$(get_field_id "RICE Reach")
IMPACT_FIELD_ID=$(get_field_id "RICE Impact")
CONFIDENCE_FIELD_ID=$(get_field_id "RICE Confidence")
EFFORT_FIELD_ID=$(get_field_id "RICE Effort")
SCORE_FIELD_ID=$(get_field_id "RICE Score")

for fid_var in REACH_FIELD_ID IMPACT_FIELD_ID CONFIDENCE_FIELD_ID EFFORT_FIELD_ID SCORE_FIELD_ID; do
  if [[ -z "${!fid_var}" ]]; then
    echo "ERROR: ${fid_var} not found on project board. Run scripts/setup-prioritize.sh first."
    exit 1
  fi
done

# Update each field on the project item.
# Uses --input - with jq-built JSON variables to ensure proper Float coercion.
# The gh CLI's -F flag does not reliably coerce strings to GraphQL Float.
update_field() {
  local field_id="$1"
  local value="$2"
  gh api graphql --input - <<GRAPHQL_EOF
{
  "query": "mutation(\$projectId: ID!, \$itemId: ID!, \$fieldId: ID!, \$value: Float!) { updateProjectV2ItemFieldValue(input: { projectId: \$projectId, itemId: \$itemId, fieldId: \$fieldId, value: { number: \$value } }) { projectV2Item { id } } }",
  "variables": $(jq -n --arg pid "${PROJECT_ID}" --arg iid "${ITEM_ID}" --arg fid "${field_id}" --argjson val "${value}" '{projectId: $pid, itemId: $iid, fieldId: $fid, value: $val}')
}
GRAPHQL_EOF
}

echo "Writing scores to project board..."
update_field "${REACH_FIELD_ID}" "${REACH}"
update_field "${IMPACT_FIELD_ID}" "${IMPACT}"
update_field "${CONFIDENCE_FIELD_ID}" "${CONFIDENCE}"
update_field "${EFFORT_FIELD_ID}" "${EFFORT}"
update_field "${SCORE_FIELD_ID}" "${SCORE}"
echo "Project fields updated."

# Board reranking by RICE Score is deferred — the Projects V2 board supports
# sorting by custom fields natively, avoiding N sequential API mutations and
# secondary rate limit risk. See future work in the PR description.

# --- Post reasoning comment ---

COMMENT=$(cat <<COMMENT_EOF
<!-- fullsend:prioritize-agent -->
**RICE Priority Score: ${SCORE}**

<details>
<summary>Score breakdown</summary>

| Dimension | Score | Reasoning |
|-----------|-------|-----------|
| **Reach** | ${REACH} | ${REASONING_REACH} |
| **Impact** | ${IMPACT} | ${REASONING_IMPACT} |
| **Confidence** | ${CONFIDENCE} | ${REASONING_CONFIDENCE} |
| **Effort** | ${EFFORT} | ${REASONING_EFFORT} |

**Formula:** (${REACH} x ${IMPACT} x ${CONFIDENCE}) / ${EFFORT} = **${SCORE}**

</details>
COMMENT_EOF
)

echo "Posting RICE comment..."
printf '%s' "${COMMENT}" | fullsend post-comment --repo "${REPO}" --number "${ISSUE_NUMBER}" --marker "<!-- fullsend:prioritize-agent -->" --token "${GH_TOKEN}" --result -
echo "Post-prioritize complete."
