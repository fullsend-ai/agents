#!/usr/bin/env bash
# post-critique.sh — Process critique agent output.
#
# Reads the critique result and performs one of:
#   - verdict=approved + AUTO_CREATE=true: creates child issues immediately
#   - verdict=approved + AUTO_CREATE=false: posts approval, adds label for human gate
#   - verdict=revise + under iteration limit: posts feedback, signals refine via label
#   - verdict=revise + at iteration limit: posts final plan for human decision
#
# Agents are decoupled — they communicate through labels and issue attachments.
#
# Required env vars:
#   ISSUE_KEY      — Issue identifier (Jira key or GH issue number)
#   ISSUE_SOURCE   — "jira" or "github"
#   GH_TOKEN       — GitHub token
#
# GitHub flow env vars:
#   GITHUB_ISSUE_NUMBER — GitHub issue number
#   REPO_FULL_NAME      — owner/repo
#   PUSH_TOKEN          — Token with write access
#
# Jira flow env vars:
#   JIRA_HOST, JIRA_EMAIL, JIRA_API_TOKEN
#
# Critique flow env vars:
#   REVIEW_ROUND        — Current review round (default: 1)
#   MAX_REVIEW_ROUNDS   — Max rounds (default: 3)
#   AUTO_CREATE         — "true" to auto-create on approval (default: "false")
#   REFINE_RUN_ID       — Run ID of the refine stage
#
# NOTE: This script uses comment-helpers.sh and create-children.sh from
# the scripts/ directory.

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

REVIEW_ROUND="${REVIEW_ROUND:-1}"
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}"
AUTO_CREATE="${AUTO_CREATE:-false}"

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

echo "Reading critique result from: ${RESULT_FILE}"

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

VERDICT=$(jq -r '.verdict' "${RESULT_FILE}")
COMMENT=$(jq -r '.comment // ""' "${RESULT_FILE}")
OVERALL_SCORE=$(jq -r '.assessment.overall // 0' "${RESULT_FILE}")
REVISION_COUNT=$(jq '.revisions // [] | length' "${RESULT_FILE}")

echo "Verdict: ${VERDICT}, Overall score: ${OVERALL_SCORE}, Revisions: ${REVISION_COUNT}, Round: ${REVIEW_ROUND}/${MAX_REVIEW_ROUNDS}"

# --- Determine reply target ---
USE_GITHUB=false
if [[ -n "${GITHUB_ISSUE_NUMBER:-}" && "${GITHUB_ISSUE_NUMBER}" != "" && "${GITHUB_ISSUE_NUMBER}" != "N/A" ]]; then
  USE_GITHUB=true
elif [[ "${ISSUE_SOURCE:-}" == "github" ]]; then
  USE_GITHUB=true
  GITHUB_ISSUE_NUMBER="${ISSUE_KEY}"
fi

RUN_URL="https://github.com/${GITHUB_REPOSITORY:-${REPO_FULL_NAME:-unknown}}/actions/runs/${GITHUB_RUN_ID:-}"
RUN_LINK="[Run #${GITHUB_RUN_ID:-manual}](${RUN_URL})"

AGENT_HEADER="## Critique Agent — Round ${REVIEW_ROUND}

**Run**: ${RUN_LINK}"

echo "Reply target: $(if $USE_GITHUB; then echo "GitHub #${GITHUB_ISSUE_NUMBER}"; else echo "Jira ${ISSUE_KEY}"; fi)"

init_comment_helpers "critique" "$USE_GITHUB"

# --- Update critique history ---
CRITIQUE_HISTORY_FILE="/tmp/workspace/critique-history.json"
if [[ -f "$CRITIQUE_HISTORY_FILE" ]]; then
  UPDATED_HISTORY=$(jq --argjson round "$REVIEW_ROUND" \
    --arg verdict "$VERDICT" \
    --argjson score "$OVERALL_SCORE" \
    --argjson revisions "$(jq '.revisions // []' "$RESULT_FILE")" \
    '.rounds += [{"round": $round, "verdict": $verdict, "overall_score": $score, "revisions": $revisions}]' \
    "$CRITIQUE_HISTORY_FILE")
  echo "$UPDATED_HISTORY" > "$CRITIQUE_HISTORY_FILE"
else
  jq -n --argjson round "$REVIEW_ROUND" \
    --arg verdict "$VERDICT" \
    --argjson score "$OVERALL_SCORE" \
    --argjson revisions "$(jq '.revisions // []' "$RESULT_FILE")" \
    '{rounds: [{"round": $round, "verdict": $verdict, "overall_score": $score, "revisions": $revisions}]}' \
    > "$CRITIQUE_HISTORY_FILE"
fi

# --- Save critique feedback for downstream consumption ---
cp "$RESULT_FILE" "/tmp/workspace/critique-feedback.json"

# --- Attach critique feedback to the issue (issue-as-rendezvous) ---
CRITIQUE_ATTACHMENT_NAME="critique-feedback.json"

if [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
  AUTH_ATTACH=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  EXISTING_ID=$(curl -sSf \
    -H "Authorization: Basic $AUTH_ATTACH" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}?fields=attachment" \
    | jq -r --arg name "$CRITIQUE_ATTACHMENT_NAME" \
      '.fields.attachment[] | select(.filename == $name) | .id' \
    | head -1 2>/dev/null || true)

  if [[ -n "$EXISTING_ID" ]]; then
    echo "Removing prior ${CRITIQUE_ATTACHMENT_NAME} attachment (id: ${EXISTING_ID})"
    curl -sSf -X DELETE \
      -H "Authorization: Basic $AUTH_ATTACH" \
      "https://${JIRA_HOST}/rest/api/3/attachment/${EXISTING_ID}" > /dev/null 2>&1 || true
  fi

  ATTACH_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Basic $AUTH_ATTACH" \
    -H "X-Atlassian-Token: no-check" \
    -F "file=@/tmp/workspace/${CRITIQUE_ATTACHMENT_NAME}" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/attachments")

  if [[ "$ATTACH_HTTP" =~ ^2 ]]; then
    echo "::notice::Attached ${CRITIQUE_ATTACHMENT_NAME} to ${ISSUE_KEY}"
  else
    echo "::warning::Failed to attach ${CRITIQUE_ATTACHMENT_NAME} to ${ISSUE_KEY} (HTTP ${ATTACH_HTTP})"
  fi
fi

# --- Process based on verdict ---

if [[ "${VERDICT}" == "approved" ]]; then
  echo "::notice::Critique approved the refinement plan (round ${REVIEW_ROUND})"

  FULL_COMMENT="${AGENT_HEADER}

| | |
|---|---|
| **Verdict** | Approved |
| **Score** | ${OVERALL_SCORE}/100 |

---

### Assessment

${COMMENT}"

  if [[ "${AUTO_CREATE}" == "true" ]]; then
    echo "Auto-create enabled — creating child issues..."

    sticky_comment "$FULL_COMMENT"

    REFINE_RESULT_FILE="/tmp/workspace/refine-result.json"
    if [[ ! -f "$REFINE_RESULT_FILE" ]]; then
      echo "::error::Refine result not found at ${REFINE_RESULT_FILE}"
      exit 1
    fi

    export RESULT_FILE="$REFINE_RESULT_FILE"
    source "${SCRIPT_DIR}/create-children.sh"

    CHILD_SUMMARY="Created ${CREATED_CHILD_COUNT:-0} child issue(s): ${CREATED_CHILD_KEYS:-none}"
    echo "::notice::${CHILD_SUMMARY}"

    CREATION_COMMENT="## Issue Creator

**Child issues created** after critique approval.

${CHILD_SUMMARY}"
    new_comment "$CREATION_COMMENT"

  else
    echo "Auto-create disabled — posting approval for human review"

    PLAN_CHILD_COUNT=$(jq '.children | length' "/tmp/workspace/refine-result.json" 2>/dev/null || echo "0")

    APPROVAL_COMMENT="${FULL_COMMENT}

---

> **Ready for human approval.** The plan proposes ${PLAN_CHILD_COUNT} child issue(s). To create them, comment \`/fs-create\`. To request changes, reply with your feedback."

    sticky_comment "$APPROVAL_COMMENT"

    if $USE_GITHUB; then
      add_label "${REPO_FULL_NAME}" "$GITHUB_ISSUE_NUMBER" "refine-approved"
    fi
  fi

elif [[ "${VERDICT}" == "revise" ]]; then
  NEXT_ROUND=$((REVIEW_ROUND + 1))

  if [[ $NEXT_ROUND -gt $MAX_REVIEW_ROUNDS ]]; then
    echo "::warning::Max review rounds (${MAX_REVIEW_ROUNDS}) reached — escalating to human"

    PLAN_CHILD_COUNT=$(jq '.children | length' "/tmp/workspace/refine-result.json" 2>/dev/null || echo "0")

    ESCALATION_COMMENT="${AGENT_HEADER}

| | |
|---|---|
| **Verdict** | Max Rounds Reached |
| **Score** | ${OVERALL_SCORE}/100 |
| **Rounds** | ${MAX_REVIEW_ROUNDS}/${MAX_REVIEW_ROUNDS} |

---

### Assessment

${COMMENT}

---

> **Human decision needed.** The critique agent still has concerns after ${MAX_REVIEW_ROUNDS} rounds. The plan proposes ${PLAN_CHILD_COUNT} child issue(s).

**Options:**
- \`/fs-create\` — create issues as-is
- \`/fs-refine\` — restart the refinement process
- Reply with specific guidance for the refine agent"

    sticky_comment "$ESCALATION_COMMENT"

    if $USE_GITHUB; then
      add_label "${REPO_FULL_NAME}" "$GITHUB_ISSUE_NUMBER" "refine-needs-human"
      add_label "${REPO_FULL_NAME}" "$GITHUB_ISSUE_NUMBER" "refine-escalated"
    fi

    if [[ -f "$CRITIQUE_HISTORY_FILE" ]]; then
      UPDATED=$(jq '.rounds[-1].escalated = true | .rounds[-1].escalation_reason = "max_rounds"' "$CRITIQUE_HISTORY_FILE")
      echo "$UPDATED" > "$CRITIQUE_HISTORY_FILE"
    fi

  else
    echo "::notice::Critique requests revisions — signaling refine via label (round ${NEXT_ROUND})"

    REVISION_COMMENT="${AGENT_HEADER}

| | |
|---|---|
| **Verdict** | Revisions Requested |
| **Score** | ${OVERALL_SCORE}/100 |
| **Revisions** | ${REVISION_COUNT} requested |

---

### Feedback

${COMMENT}

---

> Issue labeled \`ready-to-refine\` for revision round ${NEXT_ROUND}."

    sticky_comment "$REVISION_COMMENT"

    if $USE_GITHUB; then
      add_label "${REPO_FULL_NAME}" "$GITHUB_ISSUE_NUMBER" "ready-to-refine"
      add_label "${REPO_FULL_NAME}" "$GITHUB_ISSUE_NUMBER" "refine-revision-round-${NEXT_ROUND}"
      echo "::notice::Added labels 'ready-to-refine' and 'refine-revision-round-${NEXT_ROUND}' for revision round ${NEXT_ROUND}"
    fi

    if [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
      AUTH_LABEL=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
      curl -sSf -X PUT \
        -H "Authorization: Basic $AUTH_LABEL" \
        -H "Content-Type: application/json" \
        -d "{\"update\":{\"labels\":[{\"add\":\"ready-to-refine\"},{\"add\":\"refine-revision-round-${NEXT_ROUND}\"}]}}" \
        "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}" > /dev/null 2>&1 || true
      echo "::notice::Added labels 'ready-to-refine' and 'refine-revision-round-${NEXT_ROUND}' to Jira ${ISSUE_KEY}"
    fi

  fi

elif [[ "${VERDICT}" == "needs_input" ]]; then
  echo "::notice::Critique needs human input — posting question"

  QUESTION_DIM=$(jq -r '.question.dimension // "unknown"' "${RESULT_FILE}")
  QUESTION_TEXT=$(jq -r '.question.text // ""' "${RESULT_FILE}")
  QUESTION_IMPACT=$(jq -r '.question.impact // ""' "${RESULT_FILE}")

  QUESTION_COMMENT="${AGENT_HEADER}

| | |
|---|---|
| **Verdict** | Needs Human Input |
| **Score** | ${OVERALL_SCORE}/100 |
| **Dimension** | ${QUESTION_DIM} |

---

### Assessment

${COMMENT}

---

### Question

**${QUESTION_DIM}**: ${QUESTION_TEXT}

**Why this matters**: ${QUESTION_IMPACT}

> Reply with your answer, then comment \`/fs-refine\` to restart the pipeline with the new context."

  sticky_comment "$QUESTION_COMMENT"

  if $USE_GITHUB; then
    add_label "${REPO_FULL_NAME}" "$GITHUB_ISSUE_NUMBER" "refine-needs-input"
  fi

else
  echo "ERROR: Unknown verdict '${VERDICT}'"
  exit 1
fi

echo "Post-critique complete."
