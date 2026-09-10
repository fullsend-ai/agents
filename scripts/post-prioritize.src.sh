#!/usr/bin/env bash
# post-prioritize.sh — Write RICE scores to the project board and post a reasoning comment.
#
# Runs on the host after sandbox cleanup. Working directory is the fullsend
# run output directory (e.g., /tmp/fullsend/agent-prioritize-<id>/).
#
# Required env vars:
#   ISSUE_URL      — HTML URL of the issue
#   FULLSEND_FORGE — "github" or "gitlab"
#
# GitHub-specific env vars (consumed inside github-prioritize-ops.lib.sh):
#   GH_TOKEN       — GitHub token with project write + issues write scope
#   ORG            — GitHub organization
#   PROJECT_NUMBER — Project board number
#
# GitLab-specific env vars (consumed inside gitlab-prioritize-ops.lib.sh):
#   GITLAB_TOKEN   — GitLab personal/project access token

set -euo pipefail

: "${ISSUE_URL:?ISSUE_URL must be set}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prioritize-ops.lib.sh
source "${SCRIPT_DIR}/lib/prioritize-ops.lib.sh"

forge_validate_issue_url
forge_parse_issue_url

# Find the result JSON — prefer the validated iteration when set.
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent. No containment check
# (realpath / prefix guard) is applied here; the value is trusted from the
# external harness. If the trust model changes, add a realpath prefix check.
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  if [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  elif [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/result.json"
  else
    echo "ERROR: FULLSEND_VALIDATED_ITERATION_DIR is set but contains neither agent-result.json nor result.json" >&2
    exit 1
  fi
else
  # Backward compatibility: scan iteration-N/ subdirectories for the last one's output.
  RESULT_FILE=""
  for dir in iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      RESULT_FILE="${dir}/agent-result.json"
    fi
  done
fi

if [[ -z "${RESULT_FILE}" ]]; then
  echo "ERROR: agent-result.json not found in any iteration output directory" >&2
  exit 1
fi

echo "Reading RICE result from: ${RESULT_FILE}"

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON" >&2
  exit 1
fi

# Extract scores.
REACH=$(jq -r '.reach' "${RESULT_FILE}")
IMPACT=$(jq -r '.impact' "${RESULT_FILE}")
CONFIDENCE=$(jq -r '.confidence' "${RESULT_FILE}")
EFFORT=$(jq -r '.effort' "${RESULT_FILE}")

for var_name in REACH IMPACT CONFIDENCE EFFORT; do
  val="${!var_name}"
  if ! jq -e 'type == "number"' <<< "${val}" &>/dev/null; then
    safe_val="${val//::/}"
    safe_val="${safe_val//%0A/}"
    safe_val="${safe_val//%0a/}"
    safe_val="${safe_val//%0D/}"
    safe_val="${safe_val//%0d/}"
    echo "::error::${var_name} is not a valid number: '${safe_val}'" >&2
    exit 1
  fi
done
if jq -e '. == 0' <<< "${EFFORT}" &>/dev/null; then
  echo "::error::EFFORT is 0 — cannot compute RICE score (division by zero)" >&2
  exit 1
fi

# Compute final RICE score: (R * I * C) / E
SCORE=$(jq -n --argjson r "${REACH}" --argjson i "${IMPACT}" \
  --argjson c "${CONFIDENCE}" --argjson e "${EFFORT}" \
  '(($r * $i * $c / $e) * 100 | round) / 100')

echo "RICE scores: R=${REACH} I=${IMPACT} C=${CONFIDENCE} E=${EFFORT} → Score=${SCORE}"

# Extract reasoning — sanitize for markdown table embedding:
#   1. Strip HTML tags to prevent HTML/markdown injection from attacker-controlled issue content.
#   2. Escape pipe characters to avoid breaking the markdown table layout.
REASONING_REACH=$(jq -r '.reasoning.reach' "${RESULT_FILE}" | sed 's/<[^>]*>//g; s/|/\\|/g')
REASONING_IMPACT=$(jq -r '.reasoning.impact' "${RESULT_FILE}" | sed 's/<[^>]*>//g; s/|/\\|/g')
REASONING_CONFIDENCE=$(jq -r '.reasoning.confidence' "${RESULT_FILE}" | sed 's/<[^>]*>//g; s/|/\\|/g')
REASONING_EFFORT=$(jq -r '.reasoning.effort' "${RESULT_FILE}" | sed 's/<[^>]*>//g; s/|/\\|/g')

# --- Write scores to the project board ---

forge_update_project_scores "${REACH}" "${IMPACT}" "${CONFIDENCE}" "${EFFORT}" "${SCORE}"

# Board reranking by RICE Score is deferred — the Projects V2 board supports
# sorting by custom fields natively, avoiding N sequential API mutations and
# secondary rate limit risk. See future work in the PR description.

# --- Post reasoning comment ---

# Build comment body with jq to avoid shell expansion of reasoning strings.
# Reasoning text originates from agent output processing untrusted issue content;
# using jq --arg ensures no shell interpretation of backticks or $(...) sequences.
COMMENT=$(jq -n \
  --arg score "${SCORE}" \
  --arg reach "${REACH}" \
  --arg impact "${IMPACT}" \
  --arg confidence "${CONFIDENCE}" \
  --arg effort "${EFFORT}" \
  --arg r_reach "${REASONING_REACH}" \
  --arg r_impact "${REASONING_IMPACT}" \
  --arg r_confidence "${REASONING_CONFIDENCE}" \
  --arg r_effort "${REASONING_EFFORT}" \
  -r '"**RICE Priority Score: \($score)**

<details>
<summary>Score breakdown</summary>

| Dimension | Score | Reasoning |
|-----------|-------|-----------|
| **Reach** | \($reach) | \($r_reach) |
| **Impact** | \($impact) | \($r_impact) |
| **Confidence** | \($confidence) | \($r_confidence) |
| **Effort** | \($effort) | \($r_effort) |

**Formula:** (\($reach) x \($impact) x \($confidence)) / \($effort) = **\($score)**

</details>"')

echo "Posting RICE comment..."
forge_post_sticky_comment "${COMMENT}" "<!-- fullsend:prioritize-agent -->"
echo "Post-prioritize complete."
