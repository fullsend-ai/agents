#!/usr/bin/env bash
# post-explore.sh — Store exploration results and post summary.
#
# Validates agent output, attaches exploration_context.json to Jira issues,
# posts a sticky summary comment, and optionally applies pipeline labels when
# EXPLORE_READY_LABEL / EXPLORE_NEEDS_INFO_LABEL are configured.
#
# Required env vars:
#   ISSUE_KEY      — Issue identifier
#   ISSUE_SOURCE   — "jira" or "github"
#   REPO_FULL_NAME — owner/repo
#   GH_TOKEN       — GitHub token

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Companion resolution for harness base: composition (ADR-0045).
# URL-fetched scripts are isolated blobs without siblings. Prefer install copies
# under GITHUB_WORKSPACE/.fullsend/scripts or FULLSEND_DIR/scripts (overlay pattern).
_resolve_companion() {
  local name="$1"
  if [[ -f "${SCRIPT_DIR}/${name}" ]]; then
    printf '%s\n' "${SCRIPT_DIR}/${name}"
    return 0
  fi
  local d
  for d in \
    "${GITHUB_WORKSPACE:+${GITHUB_WORKSPACE}/.fullsend/scripts}" \
    "${FULLSEND_DIR:+${FULLSEND_DIR}/scripts}"; do
    if [[ -n "${d}" && -f "${d}/${name}" ]]; then
      printf '%s\n' "${d}/${name}"
      return 0
    fi
  done
  echo "ERROR: companion ${name} not found next to ${BASH_SOURCE[0]} or under install .fullsend/scripts." >&2
  echo "Installs using harness base: should override pre_script/post_script locally, or vendor companions into .fullsend/scripts/." >&2
  return 1
}

# shellcheck disable=SC1090
source "$(_resolve_companion comment-helpers.sh)"

validate_label_name() {
  local label="$1"
  if [[ ! "${label}" =~ ^[a-zA-Z0-9._/:\ +\-]+$ ]]; then
    echo "::warning::Refused pipeline label '${label}' -- contains invalid characters"
    return 1
  fi
  return 0
}

github_label_exists() {
  local label="$1"
  echo "${EXISTING_GH_LABELS}" | grep -qFx "${label}"
}

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

echo "Reading exploration result from: ${RESULT_FILE}"

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

OVERALL_CONFIDENCE=$(jq -r '.confidence.overall // 0' "${RESULT_FILE}")
GAP_COUNT=$(jq '.gaps // [] | length' "${RESULT_FILE}")
RELATED_COUNT=$(jq '.related_work // [] | length' "${RESULT_FILE}")

echo "::notice::Exploration complete: confidence=${OVERALL_CONFIDENCE}, gaps=${GAP_COUNT}, related_work=${RELATED_COUNT}"

WORKSPACE="/tmp/workspace"
mkdir -p "$WORKSPACE"
cp "${RESULT_FILE}" "${WORKSPACE}/exploration_context.json"

echo "Exploration context saved to ${WORKSPACE}/exploration_context.json"

# --- Attach exploration context to the issue ---
ATTACHMENT_NAME="exploration_context.json"

if [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
  validate_jira_host
  AUTH=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  EXISTING_ID=$(curl -sSf \
    -H "Authorization: Basic $AUTH" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}?fields=attachment" \
    | jq -r --arg name "$ATTACHMENT_NAME" \
      '.fields.attachment[] | select(.filename == $name) | .id' \
    | head -1 2>/dev/null || true)

  if [[ -n "$EXISTING_ID" ]]; then
    echo "Removing prior ${ATTACHMENT_NAME} attachment (id: ${EXISTING_ID})"
    curl -sSf -X DELETE \
      -H "Authorization: Basic $AUTH" \
      "https://${JIRA_HOST}/rest/api/3/attachment/${EXISTING_ID}" > /dev/null 2>&1 || true
  fi

  ATTACH_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Basic $AUTH" \
    -H "X-Atlassian-Token: no-check" \
    -F "file=@${WORKSPACE}/${ATTACHMENT_NAME}" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/attachments")

  if [[ "$ATTACH_HTTP" =~ ^2 ]]; then
    echo "::notice::Attached ${ATTACHMENT_NAME} to ${ISSUE_KEY}"
  else
    echo "::warning::Failed to attach ${ATTACHMENT_NAME} to ${ISSUE_KEY} (HTTP ${ATTACH_HTTP})"
  fi
fi

# --- Optional pipeline labels (configured via env) ---
CONFIDENCE_INT=$(printf '%.0f' "$OVERALL_CONFIDENCE" 2>/dev/null || echo "0")
THRESHOLD="${EXPLORE_CONFIDENCE_THRESHOLD:-50}"
READY_LABEL="${EXPLORE_READY_LABEL:-}"
NEEDS_INFO_LABEL="${EXPLORE_NEEDS_INFO_LABEL:-}"
SIGNAL_LABEL=""
STATUS_MSG="Exploration complete (confidence: ${CONFIDENCE_INT}/100)."

if [[ -n "$READY_LABEL" || -n "$NEEDS_INFO_LABEL" ]]; then
  if [[ "$CONFIDENCE_INT" -ge "$THRESHOLD" && -n "$READY_LABEL" ]]; then
    if validate_label_name "$READY_LABEL"; then
      SIGNAL_LABEL="$READY_LABEL"
      STATUS_MSG="Exploration complete. Issue labeled \`${SIGNAL_LABEL}\` for the next pipeline stage."
    fi
  elif [[ "$CONFIDENCE_INT" -lt "$THRESHOLD" && -n "$NEEDS_INFO_LABEL" ]]; then
    if validate_label_name "$NEEDS_INFO_LABEL"; then
      SIGNAL_LABEL="$NEEDS_INFO_LABEL"
      STATUS_MSG="Exploration found insufficient context (confidence: ${CONFIDENCE_INT}/${THRESHOLD}). Issue labeled \`${SIGNAL_LABEL}\` — additional input may be needed."
    fi
  fi
fi

# --- Add label when configured (skip labels that do not already exist on GitHub) ---
if [[ -n "$SIGNAL_LABEL" ]]; then
  if [[ -n "${GITHUB_ISSUE_NUMBER:-}" && "${GITHUB_ISSUE_NUMBER}" != "N/A" ]]; then
    EXISTING_GH_LABELS=$(gh api "repos/${REPO_FULL_NAME}/labels" --paginate --jq '.[].name' 2>/dev/null || true)
    if github_label_exists "$SIGNAL_LABEL"; then
      gh api "repos/${REPO_FULL_NAME}/issues/${GITHUB_ISSUE_NUMBER}/labels" \
        -f "labels[]=${SIGNAL_LABEL}" --silent 2>/dev/null || true
      echo "::notice::Added label '${SIGNAL_LABEL}' to GitHub issue #${GITHUB_ISSUE_NUMBER}"
    else
      echo "::warning::Skipping label '${SIGNAL_LABEL}' -- does not exist in repo (will not auto-create)"
    fi
  fi

  if [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    validate_jira_host
    AUTH=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
    curl -sSf -X PUT \
      -H "Authorization: Basic $AUTH" \
      -H "Content-Type: application/json" \
      -d "{\"update\":{\"labels\":[{\"add\":\"${SIGNAL_LABEL}\"}]}}" \
      "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}" > /dev/null 2>&1 || true
    echo "::notice::Added label '${SIGNAL_LABEL}' to Jira ${ISSUE_KEY}"
  fi
fi

# --- Post exploration summary comment (sticky) ---
USE_GITHUB=false
if [[ "${ISSUE_SOURCE}" == "github" && -n "${GITHUB_ISSUE_NUMBER:-}" && "${GITHUB_ISSUE_NUMBER}" != "N/A" ]]; then
  USE_GITHUB=true
fi
init_comment_helpers "explore" "$USE_GITHUB"

EXPLORE_SUMMARY=$(jq -r '.summary // "Exploration complete."' "${RESULT_FILE}")

if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  RUN_URL="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  RUN_LINK="[Run #${GITHUB_RUN_ID}](${RUN_URL})"
else
  RUN_LINK="manual run"
fi

# Extract structured data from result JSON
GAPS_SECTION=""
if [[ "$GAP_COUNT" -gt 0 ]]; then
  GAPS_LIST=$(jq -r '(.gaps // [])[] | if type == "object" then "- **\(.dimension // "definition gap")**: \(.description // .text // tostring)" else "- \(tostring)" end' "${RESULT_FILE}" 2>/dev/null | head -8 || true)
  if [[ -n "$GAPS_LIST" ]]; then
    GAPS_SECTION="
### Definition Gaps Identified (${GAP_COUNT})

${GAPS_LIST}"
  fi
fi

RELATED_SECTION=""
if [[ "$RELATED_COUNT" -gt 0 ]]; then
  JIRA_BROWSE="${JIRA_HOST:+https://${JIRA_HOST}/browse/}"
  RELATED_LIST=$(jq -r --arg browse "${JIRA_BROWSE:-}" '(.related_work // [])[] | if type == "object" then
    (if $browse != "" and (.key // "" | test("^[A-Z]+-[0-9]+$")) then
      "- [\(.key)](\($browse)\(.key)): \(.summary // .title // .description // tostring)"
    else
      "- **\(.key // .id // "item")**: \(.summary // .title // .description // tostring)"
    end)
  else "- \(tostring)" end' "${RESULT_FILE}" 2>/dev/null | head -6 || true)
  if [[ -n "$RELATED_LIST" ]]; then
    RELATED_SECTION="
### Related Work (${RELATED_COUNT})

${RELATED_LIST}"
  fi
fi

DATA_SOURCES_SECTION=""
ACCESSED_CSV=$(jq -r '(.data_sources.accessed // []) | join(", ")' "${RESULT_FILE}" 2>/dev/null || true)
NOT_ACCESSED_CSV=$(jq -r '(.data_sources.not_accessed // []) | join(", ")' "${RESULT_FILE}" 2>/dev/null || true)

if [[ -n "$ACCESSED_CSV" || -n "$NOT_ACCESSED_CSV" ]]; then
  DATA_SOURCES_SECTION="

### Data Sources

"
  if [[ -n "$ACCESSED_CSV" ]]; then
    DATA_SOURCES_SECTION+="**Accessed:** ${ACCESSED_CSV}
"
  fi
  if [[ -n "$NOT_ACCESSED_CSV" ]]; then
    DATA_SOURCES_SECTION+="
**Not available:** ${NOT_ACCESSED_CSV}"
  fi
fi

EXPLORE_COMMENT="## 🔍 Explore Agent

| | |
|---|---|
| **Run** | ${RUN_LINK} |
| **Confidence** | ${OVERALL_CONFIDENCE}/100 |
| **Definition Gaps** | ${GAP_COUNT} identified |
| **Related Work** | ${RELATED_COUNT} items |

---

### Summary

${EXPLORE_SUMMARY}
${GAPS_SECTION}
${RELATED_SECTION}
${DATA_SOURCES_SECTION}

---

> ${STATUS_MSG}"

sticky_comment "$EXPLORE_COMMENT"

echo "Post-explore complete."
