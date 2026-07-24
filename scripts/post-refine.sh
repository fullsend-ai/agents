#!/usr/bin/env bash
# post-refine.sh — Process refine agent output and signal readiness for critique.
#
# The refine agent ALWAYS produces a plan (status=complete). This script
# posts a summary comment and adds a label to signal the critique agent.
# Agents are decoupled — they communicate through labels and issue attachments.
#
# Issue creation is handled downstream by the critique agent's approval flow,
# NOT by this script. See post-critique.sh and create-children.sh.
#
# Routing: results go back to the same system that owns the work item.
#   - GitHub flow: GITHUB_ISSUE_NUMBER is set → post to GitHub issue
#   - Jira flow: GITHUB_ISSUE_NUMBER is empty → post to Jira
#
# Required env vars:
#   ISSUE_KEY      — Issue identifier (Jira key or GH issue number)
#   ISSUE_SOURCE   — "jira" or "github"
#   GH_TOKEN       — GitHub token
#
# GitHub flow env vars:
#   GITHUB_ISSUE_NUMBER — GitHub issue number to post results to
#   REPO_FULL_NAME      — owner/repo
#   PUSH_TOKEN          — Token with write access
#
# Jira flow env vars:
#   JIRA_HOST, JIRA_EMAIL, JIRA_API_TOKEN
#
# Critique flow env vars (passed through from critique → refine loop):
#   REVIEW_ROUND        — Current review round (default: 1)
#   MAX_REVIEW_ROUNDS   — Max rounds (default: 3)
#   AUTO_CREATE         — "true" to auto-create on approval (default: "false")
#
# NOTE: This script uses comment-helpers.sh and markdown-to-adf.py from
# the explore agent. These must be present in the scripts/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Companion resolution for harness base: composition (ADR-0045).
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


if [[ ! -f "${SCRIPT_DIR}/comment-helpers.sh" ]]; then
  echo "ERROR: comment-helpers.sh not found (requires PR #11 explore agent)"
  exit 1
fi
# shellcheck disable=SC1090
source "$(_resolve_companion comment-helpers.sh)"

# Strip GHA workflow-command metacharacters from interpolated log output.
sanitize_gha() {
  local val="$1"
  val="${val//::/}"
  val="${val//%0A/}"
  val="${val//%0a/}"
  val="${val//%0D/}"
  val="${val//%0d/}"
  printf '%s' "${val}"
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

echo "Reading refine result from: ${RESULT_FILE}"

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

STATUS=$(jq -r '.status' "${RESULT_FILE}")
COMMENT=$(jq -r '.comment // ""' "${RESULT_FILE}")
CONFIDENCE=$(jq -r '.confidence.overall // 0' "${RESULT_FILE}")

echo "Status: ${STATUS}, Confidence: ${CONFIDENCE}"

USE_GITHUB=false
if [[ -n "${GITHUB_ISSUE_NUMBER:-}" && "${GITHUB_ISSUE_NUMBER}" != "" && "${GITHUB_ISSUE_NUMBER}" != "N/A" ]]; then
  USE_GITHUB=true
elif [[ "${ISSUE_SOURCE:-}" == "github" ]]; then
  USE_GITHUB=true
  GITHUB_ISSUE_NUMBER="${ISSUE_KEY}"
fi

echo "Reply target: $(if $USE_GITHUB; then echo "GitHub #${GITHUB_ISSUE_NUMBER}"; else echo "Jira ${ISSUE_KEY}"; fi)"

REVIEW_ROUND="${REVIEW_ROUND:-1}"
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}"
AUTO_CREATE="${AUTO_CREATE:-false}"
IS_REVISION=$([[ "$REVIEW_ROUND" -gt 1 ]] && echo "true" || echo "false")

RUN_URL="https://github.com/${GITHUB_REPOSITORY:-${REPO_FULL_NAME:-unknown}}/actions/runs/${GITHUB_RUN_ID:-}"
RUN_LINK="[Run #${GITHUB_RUN_ID:-manual}](${RUN_URL})"

AGENT_HEADER="## Refine Agent

**Run**: ${RUN_LINK}"
if [[ "$IS_REVISION" == "true" ]]; then
  AGENT_HEADER="## Refine Agent — Revision ${REVIEW_ROUND}

**Run**: ${RUN_LINK}"
fi

init_comment_helpers "refine" "$USE_GITHUB"

# --- Post plan and signal critique ---

CONFIDENCE_INT=$(printf '%.0f' "$CONFIDENCE" 2>/dev/null || echo "0")

echo "::notice::Refine complete (confidence ${CONFIDENCE_INT}/100) — posting proposed plan and signaling critique"

if $USE_GITHUB; then
  remove_label "${REPO_FULL_NAME}" "$GITHUB_ISSUE_NUMBER" "ready-to-refine"
  remove_label "${REPO_FULL_NAME}" "$GITHUB_ISSUE_NUMBER" "refine-needs-input"
  remove_label "${REPO_FULL_NAME}" "$GITHUB_ISSUE_NUMBER" "human-refinement"
fi

CHILD_COUNT=$(jq '.children | length' "${RESULT_FILE}" 2>/dev/null || echo "0")
OPEN_QUESTION_COUNT=$(jq '.open_questions | length' "${RESULT_FILE}" 2>/dev/null || echo "0")

EPIC_COUNT=$(jq '[.children[]? | select(.type == "epic")] | length' "${RESULT_FILE}" 2>/dev/null || echo "0")
STORY_COUNT=$(jq '[.children[]? | select(.type == "story")] | length' "${RESULT_FILE}" 2>/dev/null || echo "0")
TASK_COUNT=$(jq '[.children[]? | select(.type == "task")] | length' "${RESULT_FILE}" 2>/dev/null || echo "0")

PLAN_SUMMARY="Proposed: ${CHILD_COUNT} work items"
PLAN_PARTS=()
[[ "$EPIC_COUNT" -gt 0 ]] && PLAN_PARTS+=("${EPIC_COUNT} epics")
[[ "$STORY_COUNT" -gt 0 ]] && PLAN_PARTS+=("${STORY_COUNT} stories")
[[ "$TASK_COUNT" -gt 0 ]] && PLAN_PARTS+=("${TASK_COUNT} tasks")
if [[ ${#PLAN_PARTS[@]} -gt 0 ]]; then
  PLAN_SUMMARY="${PLAN_SUMMARY} ($(IFS=', '; echo "${PLAN_PARTS[*]}"))"
fi

if [[ "$OPEN_QUESTION_COUNT" -gt 0 ]]; then
  PLAN_SUMMARY="${PLAN_SUMMARY} · ${OPEN_QUESTION_COUNT} open question(s)"
fi

WORKFLOW_REPO="${GITHUB_REPOSITORY:-${REPO_FULL_NAME:-unknown}}"
ARTIFACT_URL="https://github.com/${WORKFLOW_REPO}/actions/runs/${GITHUB_RUN_ID:-}"

QUESTIONS_SECTION=""
if [[ "$OPEN_QUESTION_COUNT" -gt 0 ]]; then
  QUESTIONS_LIST=$(jq -r '.open_questions[]? | if type == "object" then "- **\(.dimension // "general")**: \(.question // .text // .description // tostring) — *Impact: \(.impact // "Unknown")*" else "- \(tostring)" end' "${RESULT_FILE}" 2>/dev/null || true)
  if [[ -n "$QUESTIONS_LIST" ]]; then
    QUESTIONS_SECTION="

### Open Questions (${OPEN_QUESTION_COUNT})

Reply with answers, then comment \`/fs-refine\` to re-run.

${QUESTIONS_LIST}"
  fi
fi

EXPLORE_CONTEXT_FILE="/tmp/workspace/exploration_context.json"
DATA_SOURCES_FOOTER=""
if [[ -f "$EXPLORE_CONTEXT_FILE" ]]; then
  ACCESSED=$(jq -r '(.data_sources.accessed // []) | join(", ")' "$EXPLORE_CONTEXT_FILE" 2>/dev/null || true)
  NOT_ACCESSED=$(jq -r '(.data_sources.not_accessed // []) | join(", ")' "$EXPLORE_CONTEXT_FILE" 2>/dev/null || true)
  if [[ -n "$ACCESSED" || -n "$NOT_ACCESSED" ]]; then
    DATA_SOURCES_FOOTER="
### Data Sources

**Accessed:** ${ACCESSED:-None reported}"
    if [[ -n "$NOT_ACCESSED" ]]; then
      DATA_SOURCES_FOOTER+="
**Not available:** ${NOT_ACCESSED}"
    fi
    DATA_SOURCES_FOOTER+="

"
  fi
fi

ASSUMPTIONS_SECTION=""
ASSUMPTION_COUNT=$(jq '.uncited_assumptions // [] | length' "${RESULT_FILE}" 2>/dev/null || echo "0")
if [[ "$ASSUMPTION_COUNT" -gt 0 ]]; then
  ASSUMPTIONS_LIST=$(jq -r '(.uncited_assumptions // [])[:5][] | "- \(.)"' "${RESULT_FILE}" 2>/dev/null || true)
  if [[ -n "$ASSUMPTIONS_LIST" ]]; then
    ASSUMPTIONS_SECTION="
### Assumptions (not verified)

${ASSUMPTIONS_LIST}

"
  fi
fi

PLAN_COMMENT="${AGENT_HEADER}

| | |
|---|---|
| **Confidence** | ${CONFIDENCE}/100 |
| **Work Items** | ${PLAN_SUMMARY} |

---

### Plan Summary

${COMMENT}
${ASSUMPTIONS_SECTION}

---

[**Full plan details** — download \`fullsend-refine\` artifact](${ARTIFACT_URL}) for the complete \`refine-result.json\` with all epics, stories, tasks, and acceptance criteria.
${QUESTIONS_SECTION}
${DATA_SOURCES_FOOTER}

---

> Issue labeled \`ready-to-critique\` for the Critique Agent."

sticky_comment "$PLAN_COMMENT"

# Update issue description if proposed_description is present
PROPOSED_DESC=$(jq -r '.proposed_description // ""' "${RESULT_FILE}")
if [[ -n "$PROPOSED_DESC" && "$PROPOSED_DESC" != "null" ]]; then
  if [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    AUTH_DESC=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
    ADF_FLAGS=""
    if [[ "$JIRA_HOST" != *"atlassian.net"* ]]; then
      ADF_FLAGS="--no-expand"
    fi
    DESC_ADF=$(printf '%s' "$PROPOSED_DESC" | python3 "$(_resolve_companion markdown-to-adf.py)" $ADF_FLAGS | jq '.body')

    DESC_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
      -X PUT \
      -H "Authorization: Basic $AUTH_DESC" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc --argjson desc "$DESC_ADF" '{fields: {description: $desc}}')" \
      "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}")

    if [[ "$DESC_HTTP" =~ ^2 ]]; then
      echo "::notice::Updated ${ISSUE_KEY} description (previous version in History tab)"
    else
      echo "::warning::Failed to update ${ISSUE_KEY} description (HTTP ${DESC_HTTP}) — falling back to comment"
      new_comment "## Proposed Feature Description

${PROPOSED_DESC}"
    fi

  elif $USE_GITHUB; then
    gh api "repos/${REPO_FULL_NAME}/issues/${GITHUB_ISSUE_NUMBER}" \
      -X PATCH --field "body=${PROPOSED_DESC}" --silent 2>/dev/null \
      && echo "::notice::Updated GitHub issue #${GITHUB_ISSUE_NUMBER} body" \
      || echo "::warning::Failed to update GitHub issue body"
  fi
fi

# Save the refine result for artifact upload and critique
cp "${RESULT_FILE}" "/tmp/workspace/refine-result.json"

# --- Attach refine result to the issue (issue-as-rendezvous) ---
ATTACHMENT_NAME="refine-result.json"

if [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
  AUTH_ATTACH=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  EXISTING_ID=$(curl -sSf \
    -H "Authorization: Basic $AUTH_ATTACH" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}?fields=attachment" \
    | jq -r --arg name "$ATTACHMENT_NAME" \
      '.fields.attachment[] | select(.filename == $name) | .id' \
    | head -1 2>/dev/null || true)

  if [[ -n "$EXISTING_ID" ]]; then
    echo "Removing prior ${ATTACHMENT_NAME} attachment (id: ${EXISTING_ID})"
    curl -sSf -X DELETE \
      -H "Authorization: Basic $AUTH_ATTACH" \
      "https://${JIRA_HOST}/rest/api/3/attachment/${EXISTING_ID}" > /dev/null 2>&1 || true
  fi

  ATTACH_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Basic $AUTH_ATTACH" \
    -H "X-Atlassian-Token: no-check" \
    -F "file=@/tmp/workspace/${ATTACHMENT_NAME}" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/attachments")

  if [[ "$ATTACH_HTTP" =~ ^2 ]]; then
    echo "::notice::Attached ${ATTACHMENT_NAME} to ${ISSUE_KEY}"
  else
    echo "::warning::Failed to attach ${ATTACHMENT_NAME} to ${ISSUE_KEY} (HTTP ${ATTACH_HTTP})"
  fi
fi

# --- Add label to signal critique stage ---
if [[ -n "${GITHUB_ISSUE_NUMBER:-}" && "${GITHUB_ISSUE_NUMBER}" != "N/A" ]]; then
  LABEL_PAYLOAD='["ready-to-critique"]'
  if [[ "$REVIEW_ROUND" -gt 1 ]]; then
    LABEL_PAYLOAD="[\"ready-to-critique\",\"refine-revision-round-${REVIEW_ROUND}\"]"
  fi
  if gh api "repos/${REPO_FULL_NAME}/issues/${GITHUB_ISSUE_NUMBER}/labels" \
    --input - <<< "{\"labels\":${LABEL_PAYLOAD}}" --silent 2>/dev/null; then
    SAFE_GH_NUM=$(sanitize_gha "${GITHUB_ISSUE_NUMBER}")
    echo "::notice::Added label 'ready-to-critique' to GitHub issue #${SAFE_GH_NUM}"
  else
    echo "::warning::Failed to add critique labels to GitHub issue #${GITHUB_ISSUE_NUMBER}"
  fi
fi

if [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
  AUTH_LABEL=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
  # Remove the trigger label before adding the critique-signaling label
  curl -sSf -X PUT \
    -H "Authorization: Basic $AUTH_LABEL" \
    -H "Content-Type: application/json" \
    -d '{"update":{"labels":[{"remove":"ready-to-refine"}]}}' \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}" > /dev/null 2>&1 || true
  LABEL_OPS='[{"add":"ready-to-critique"}]'
  if [[ "$REVIEW_ROUND" -gt 1 ]]; then
    LABEL_OPS="[{\"add\":\"ready-to-critique\"},{\"add\":\"refine-revision-round-${REVIEW_ROUND}\"}]"
  fi
  if curl -sSf -X PUT \
    -H "Authorization: Basic $AUTH_LABEL" \
    -H "Content-Type: application/json" \
    -d "{\"update\":{\"labels\":${LABEL_OPS}}}" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}" > /dev/null 2>&1; then
    SAFE_JIRA_KEY=$(sanitize_gha "${ISSUE_KEY}")
    SAFE_ROUND=$(sanitize_gha "${REVIEW_ROUND}")
    echo "::notice::Added label 'ready-to-critique' to Jira ${SAFE_JIRA_KEY} (round ${SAFE_ROUND})"
  else
    echo "::warning::Failed to add critique labels to Jira ${ISSUE_KEY} (round ${REVIEW_ROUND})"
  fi
fi

echo "Post-refine complete."
