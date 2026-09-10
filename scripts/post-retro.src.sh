#!/usr/bin/env bash
# post-retro.sh — File issues from retro agent proposals and post summary.
#
# Runs on the host after sandbox cleanup. Working directory is the fullsend
# run output directory.
#
# Required env vars:
#   ORIGINATING_URL — HTML URL of the originating PR or issue
#   FULLSEND_FORGE  — "github" or "gitlab"
#
# Forge-specific token env vars:
#   GH_TOKEN      — GitHub token (when FULLSEND_FORGE=github)
#   GITLAB_TOKEN  — GitLab token (when FULLSEND_FORGE=gitlab)
#
# The agent writes its result to output/agent-result.json (relative to
# the iteration directory). This script finds the most recent iteration's output.

set -euo pipefail

: "${ORIGINATING_URL:?ORIGINATING_URL is required}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retro-ops.lib.sh
source "${SCRIPT_DIR}/lib/retro-ops.lib.sh"

forge_require_token
forge_mask_token

# Find the retro result JSON — prefer the validated iteration when set.
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

echo "Reading retro result from: ${RESULT_FILE}"

# Validate JSON is parseable.
if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON" >&2
  exit 1
fi

# Extract repo and number from ORIGINATING_URL.
forge_validate_originating_url
forge_parse_originating_url

echo "Originating: ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}"

# Read the allowlist from config.yaml. The config repo is checked out
# at the forge-specific workspace directory by the reusable workflow.
CONFIG_WORKSPACE="$(forge_get_config_workspace)"
CONFIG_FILE="${CONFIG_WORKSPACE}/config.yaml"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  # Per-repo mode: config is under .fullsend/
  CONFIG_FILE="${CONFIG_WORKSPACE}/.fullsend/config.yaml"
fi

ALLOWED_ORGS=""
ALLOWED_REPOS=""
if [[ -f "${CONFIG_FILE}" ]] && ! command -v yq &>/dev/null; then
  echo "::warning::yq not found — cannot read create_issues.allow_targets from config; cross-repo issue creation disabled"
fi
if [[ -f "${CONFIG_FILE}" ]] && command -v yq &>/dev/null; then
  ALLOWED_ORGS=$(yq -r '.create_issues.allow_targets.orgs // [] | .[]' "${CONFIG_FILE}" 2>/dev/null || true)
  ALLOWED_REPOS=$(yq -r '.create_issues.allow_targets.repos // [] | .[]' "${CONFIG_FILE}" 2>/dev/null || true)
fi

# The originating repo is always implicitly allowed.
is_target_allowed() {
  local target_repo="$1"
  local target_org="${target_repo%%/*}"

  # Source repo is always allowed.
  if [[ "${target_repo}" == "${ORIGINATING_REPO}" ]]; then
    return 0
  fi

  # Check org allowlist.
  if [[ -n "${ALLOWED_ORGS}" ]] && echo "${ALLOWED_ORGS}" | grep -qFx "${target_org}"; then
    return 0
  fi

  # Check repo allowlist.
  if [[ -n "${ALLOWED_REPOS}" ]] && echo "${ALLOWED_REPOS}" | grep -qFx "${target_repo}"; then
    return 0
  fi

  return 1
}

# File an issue for each proposal.
PROPOSAL_COUNT=$(jq '.proposals | length' "${RESULT_FILE}")
echo "Found ${PROPOSAL_COUNT} proposal(s)"

# Validate all proposals before filing any to avoid partial state.
# Guard on PROPOSAL_COUNT > 0: `seq 0 $((PROPOSAL_COUNT - 1))` with
# PROPOSAL_COUNT=0 becomes `seq 0 -1`, which some seq implementations treat
# as a descending range (0, -1) rather than empty, causing an out-of-bounds
# proposals[0] access when there are no proposals.
if [[ "${PROPOSAL_COUNT}" -gt 0 ]]; then
  for i in $(seq 0 $((PROPOSAL_COUNT - 1))); do
    TR=$(jq -r ".proposals[$i].target_repo" "${RESULT_FILE}")
    if [[ ! "${TR}" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+$ ]]; then
      echo "ERROR: proposal[$i].target_repo is not a valid repo path: $(_gha_sanitize "${TR}")" >&2
      exit 1
    fi
    TI=$(jq -r ".proposals[$i].title // empty" "${RESULT_FILE}")
    if [[ -z "${TI}" ]]; then
      echo "ERROR: proposal[$i].title is missing or empty" >&2
      exit 1
    fi
    jq -e ".proposals[$i] | .what_happened and .what_could_go_better and .proposed_change and .validation_criteria" "${RESULT_FILE}" >/dev/null 2>&1 || {
      echo "ERROR: proposal[$i] is missing required fields" >&2
      exit 1
    }
  done
fi
echo "All ${PROPOSAL_COUNT} proposal(s) validated"

ISSUE_LINKS=""
EVIDENCE_NOTES=""
FILTERED_COUNT=0
SKIPPED_TARGETS=""
if [[ "${PROPOSAL_COUNT}" -gt 0 ]]; then
  for i in $(seq 0 $((PROPOSAL_COUNT - 1))); do
    TARGET_REPO=$(jq -r ".proposals[$i].target_repo" "${RESULT_FILE}")
    TITLE=$(jq -r ".proposals[$i].title" "${RESULT_FILE}")

    # Deterministic gate: reject "Evidence for" proposals.
    # The retro-analysis skill instructs the agent not to file these, but the
    # agent ignores the instruction frequently enough that a post-script gate
    # is needed. See fullsend-ai/fullsend#3881.
    TITLE_LOWER=$(printf '%s' "${TITLE}" | tr '[:upper:]' '[:lower:]')
    if [[ "${TITLE_LOWER}" =~ ^evidence[[:space:]]+(for|of)[[:space:]]+([\#!]) ]] || \
       [[ "${TITLE_LOWER}" =~ ^evidence: ]] || \
       [[ "${TITLE_LOWER}" =~ ^additional[[:space:]]+evidence ]]; then
      SAFE_TITLE=$(_gha_sanitize "${TITLE}")
      echo "::warning::proposal[$i] rejected — title matches evidence-for pattern: ${SAFE_TITLE}. Folding into summary."
      EVIDENCE_NOTES="${EVIDENCE_NOTES}
- **${TITLE}** (${TARGET_REPO}): $(jq -r ".proposals[$i].what_happened | split(\"\\n\")[0]" "${RESULT_FILE}")"
      FILTERED_COUNT=$((FILTERED_COUNT + 1))
      continue
    fi

    # Allowlist gate: reject proposals targeting repos not in allow_targets.
    if ! is_target_allowed "${TARGET_REPO}"; then
      echo "::warning::Skipping issue creation in '${TARGET_REPO}' — not in create_issues.allow_targets"
      SKIPPED_TARGETS="${SKIPPED_TARGETS}
- **${TITLE}** (\`${TARGET_REPO}\`)"
      continue
    fi

    # Build the issue body from the four sections.
    BODY=$(jq -r --arg url "${ORIGINATING_URL}" "
      .proposals[$i] |
      \"## What happened\n\n\" + .what_happened +
      \"\n\n## What could go better\n\n\" + .what_could_go_better +
      \"\n\n## Proposed change\n\n\" + .proposed_change +
      \"\n\n## Validation criteria\n\n\" + .validation_criteria +
      \"\n\n---\n_Generated by retro agent from \" + \$url + \"_\"
    " "${RESULT_FILE}")

    # TODO(#833): Remove this warning once per-repo customization is stable.
    # Depends on: #195, #179, #419, PR #792, PR #799.
    if [[ "${TARGET_REPO}" == */.fullsend ]]; then
      echo "::warning::proposal[$i] targets a .fullsend repo (${TARGET_REPO}). Filing in .fullsend repos is discouraged until per-repo customization patterns are stable. Consider filing in the source repo or fullsend-ai/fullsend upstream instead."
    fi

    # Ensure the label exists in the target repo before applying it.
    # Follows the same pattern as post-review.sh for ready-for-merge.
    # --force / idempotent creation makes this safe to repeat.
    forge_create_label "${TARGET_REPO}" "ready-for-triage" \
      "Triggers triage agent dispatch" "0E8A16"

    SAFE_TITLE=$(_gha_sanitize "${TITLE}")
    echo "Filing issue in ${TARGET_REPO}: ${SAFE_TITLE}"
    if ! ISSUE_URL=$(forge_create_issue "${TARGET_REPO}" "${TITLE}" "${BODY}" "ready-for-triage"); then
      echo "ERROR: failed to create issue in ${TARGET_REPO}: ${ISSUE_URL}" >&2
      exit 1
    fi

    echo "Created: ${ISSUE_URL}"
    ISSUE_LINKS="${ISSUE_LINKS}- [${TITLE}](${ISSUE_URL}) (in \`${TARGET_REPO}\`)
"
  done
fi

# Post summary comment on the originating PR/issue.
SUMMARY=$(jq -r '.summary // empty' "${RESULT_FILE}")
if [[ -z "${SUMMARY}" ]]; then
  echo "ERROR: .summary is missing or empty in agent result" >&2
  exit 1
fi

if [[ ${FILTERED_COUNT} -gt 0 ]]; then
  echo "${FILTERED_COUNT} proposal(s) filtered (evidence-for pattern)"
fi

COMMENT="${SUMMARY}"
if [[ -n "${ISSUE_LINKS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals filed\n\n%s' "${COMMENT}" "${ISSUE_LINKS}")
fi
if [[ -n "${EVIDENCE_NOTES}" ]]; then
  COMMENT=$(printf '%s\n\n### Evidence notes (not filed as issues)\n%s' "${COMMENT}" "${EVIDENCE_NOTES}")
fi
if [[ -n "${SKIPPED_TARGETS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals skipped (target repo not allowed)\n\nFile manually or update `create_issues.allow_targets` in config.yaml:\n%s' "${COMMENT}" "${SKIPPED_TARGETS}")
fi

# Truncate to forge-specific comment limit.
MAX_COMMENT_LEN=$(forge_get_comment_max_len)
if [[ ${#COMMENT} -gt ${MAX_COMMENT_LEN} ]]; then
  TRUNCATION_SUFFIX=$'\n\n...(truncated)'
  COMMENT="${COMMENT:0:$((MAX_COMMENT_LEN - ${#TRUNCATION_SUFFIX}))}"${TRUNCATION_SUFFIX}
fi

echo "Posting summary comment on ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}"
# Note: we handle 401/403 inline rather than relying on github-api-csma.sh
# because the intent is different. CSMA retries rate-limited requests; here
# we want graceful degradation when the token permanently lacks permission
# to comment on a specific repo. Retrying a 403 permission error is futile.
COMMENT_OUTPUT=""
COMMENT_EXIT=0
COMMENT_OUTPUT=$(forge_post_comment "${ORIGINATING_REPO}" "${ORIGINATING_NUMBER}" "${COMMENT}") || COMMENT_EXIT=$?

if [[ ${COMMENT_EXIT} -ne 0 ]]; then
  # Treat 401/403 as non-fatal — the token lacks permission to comment on
  # this repo, but the core deliverables (analysis + proposal issues) are
  # already complete. See #2305.
  if echo "${COMMENT_OUTPUT}" | grep -qE "HTTP (401|403)|error: (401|403)"; then
    # Sanitize before interpolating into GHA workflow command to prevent
    # injecting ::set-output or ::save-state directives via crafted responses.
    SAFE_OUTPUT=$(_gha_sanitize "${COMMENT_OUTPUT}")
    echo "::warning::Could not post summary comment to ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}: insufficient permissions (${SAFE_OUTPUT}). Skipping."
  else
    # Sanitize before echoing to prevent GHA workflow command injection.
    SAFE_OUTPUT=$(_gha_sanitize "${COMMENT_OUTPUT}")
    echo "ERROR: failed to post summary comment on ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}: ${SAFE_OUTPUT}"
    exit 1
  fi
fi

echo "Post-retro complete."
