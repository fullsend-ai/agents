#!/usr/bin/env bash
# shellcheck shell=bash
# github-prioritize-ops.lib.sh — GitHub forge operations for prioritize scripts.
#
# Bundled into pre-prioritize.sh and post-prioritize.sh via prioritize-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST/GraphQL API via CSMA helpers.
#
# Expected globals (set by forge_parse_issue_url):
#   REPO         — owner/repo (e.g., "org/repo")
#   ISSUE_NUMBER — issue number
#
# Expected env vars:
#   ISSUE_URL      — HTML URL of the issue
#   GH_TOKEN       — GitHub token with project write + issues write scope
#   ORG            — GitHub organization
#   PROJECT_NUMBER — Project board number

[[ -n "${GITHUB_PRIORITIZE_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_PRIORITIZE_OPS_SH_LOADED=1

# shellcheck source=github-api-csma.lib.sh
source "${SCRIPT_DIR}/lib/github-api-csma.lib.sh"

# --- URL handling ---

forge_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected pattern: $(_gha_sanitize "${ISSUE_URL}")" >&2
    return 1
  fi
}

forge_parse_issue_url() {
  REPO=$(echo "${ISSUE_URL}" | sed 's|https://github.com/||; s|/issues/.*||')
  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
}

# --- Project board operations ---

forge_update_project_scores() {
  local reach="$1"
  local impact="$2"
  local confidence="$3"
  local effort="$4"
  local score="$5"

  if [[ -z "${ORG:-}" || -z "${PROJECT_NUMBER:-}" ]]; then
    echo "::notice::ORG or PROJECT_NUMBER not set — skipping project board update"
    return 0
  fi

  # Resolve project and item IDs.
  local project_id
  project_id=$(github_csma_run graphql project view "${PROJECT_NUMBER}" --owner "${ORG}" --format json | jq -r '.id')

  local issue_node_id
  issue_node_id=$(github_csma_run core api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.node_id')

  # Find the project item ID for this issue via the issue's projectItems connection.
  local item_response
  item_response=$(github_csma_run graphql api graphql -f query='
    query($issueId: ID!) {
      node(id: $issueId) {
        ... on Issue {
          projectItems(first: 10) {
            nodes {
              id
              project { id }
            }
          }
        }
      }
    }
  ' -f issueId="${issue_node_id}")

  local item_id
  item_id=$(echo "${item_response}" | jq -r --arg pid "${project_id}" \
    '(.data.node.projectItems.nodes // [])[] | select(.project.id == $pid) | .id')

  if [[ -z "${item_id}" || "${item_id}" == "null" ]]; then
    echo "ERROR: issue $(_gha_sanitize "${ISSUE_URL}") not found on project board (project: ${PROJECT_NUMBER}, org: ${ORG})" >&2
    return 1
  fi

  # Get field IDs for all RICE fields.
  local fields_json
  fields_json=$(github_csma_run graphql project field-list "${PROJECT_NUMBER}" --owner "${ORG}" --format json)

  _get_field_id() {
    echo "${fields_json}" | jq -r --arg name "$1" '.fields[] | select(.name == $name) | .id'
  }

  local reach_field_id impact_field_id confidence_field_id effort_field_id score_field_id
  reach_field_id=$(_get_field_id "RICE Reach")
  impact_field_id=$(_get_field_id "RICE Impact")
  confidence_field_id=$(_get_field_id "RICE Confidence")
  effort_field_id=$(_get_field_id "RICE Effort")
  score_field_id=$(_get_field_id "RICE Score")

  local fid_var
  for fid_var in reach_field_id impact_field_id confidence_field_id effort_field_id score_field_id; do
    if [[ -z "${!fid_var}" ]]; then
      echo "ERROR: ${fid_var} not found on project board (project: ${PROJECT_NUMBER}, org: ${ORG}). Run scripts/setup-prioritize.sh first." >&2
      return 1
    fi
  done

  # Update each field on the project item.
  _update_field() {
    local field_id="$1"
    local value="$2"
    jq -n \
      --arg pid "${project_id}" \
      --arg iid "${item_id}" \
      --arg fid "${field_id}" \
      --argjson val "${value}" \
      '{
        query: "mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: Float!) { updateProjectV2ItemFieldValue(input: { projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: { number: $value } }) { projectV2Item { id } } }",
        variables: {projectId: $pid, itemId: $iid, fieldId: $fid, value: $val}
      }' | github_csma_run_pipe graphql api graphql --input -
  }

  echo "Writing scores to project board (CSMA-aware)..."
  _update_field "${reach_field_id}" "${reach}"
  _update_field "${impact_field_id}" "${impact}"
  _update_field "${confidence_field_id}" "${confidence}"
  _update_field "${effort_field_id}" "${effort}"
  _update_field "${score_field_id}" "${score}"
  echo "Project fields updated."
}

# --- Comments ---

forge_post_sticky_comment() {
  : "${GH_TOKEN:?GH_TOKEN must be set}"
  local body="$1"
  local marker="$2"
  printf '%s' "${body}" | github_csma_run_cmd core fullsend post-comment \
    --repo "${REPO}" \
    --number "${ISSUE_NUMBER}" \
    --marker "${marker}" \
    --token "${GH_TOKEN}" \
    --result - >/dev/null
}
