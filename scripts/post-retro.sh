#!/usr/bin/env bash
# GENERATED from post-retro.src.sh — DO NOT EDIT. Run: make script-build
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
# BEGIN bundled: lib/retro-ops.lib.sh
# shellcheck shell=bash
# retro-ops.lib.sh — Forge-dispatch wrapper for retro operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${RETRO_OPS_SH_LOADED:-}" ]] && return 0
RETRO_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-retro-ops.lib.sh
# shellcheck shell=bash
# github-retro-ops.lib.sh — GitHub forge operations for retro scripts.
#
# Bundled into pre-retro.sh and post-retro.sh via retro-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by forge_parse_originating_url):
#   ORIGINATING_REPO   — owner/repo (e.g., "org/repo")
#   ORIGINATING_NUMBER — issue or PR number
#
# Expected env vars:
#   ORIGINATING_URL — HTML URL of the originating PR or issue
#   GH_TOKEN        — GitHub token with issues:write and pull_requests:write scope

[[ -n "${GITHUB_RETRO_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_RETRO_OPS_SH_LOADED=1

# --- URL handling ---

forge_validate_originating_url() {
  if [[ ! "${ORIGINATING_URL}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/(issues|pull)/[0-9]+$ ]]; then
    echo "ERROR: ORIGINATING_URL does not match expected pattern: $(_gha_sanitize "${ORIGINATING_URL}")" >&2
    return 1
  fi
}

forge_parse_originating_url() {
  # shellcheck disable=SC2034 # ORIGINATING_REPO consumed by callers after function returns
  ORIGINATING_REPO=$(echo "${ORIGINATING_URL}" | sed -E 's#https://github.com/##; s#/(issues|pull)/.*##')
  # shellcheck disable=SC2034 # ORIGINATING_NUMBER consumed by callers after function returns
  ORIGINATING_NUMBER=$(basename "${ORIGINATING_URL}")
}

# --- Token handling ---

forge_mask_token() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::add-mask::${GH_TOKEN}"
  fi
}

forge_require_token() {
  : "${GH_TOKEN:?GH_TOKEN is required}"
}

# --- Config workspace ---

forge_get_config_workspace() {
  echo "${GITHUB_WORKSPACE:-/tmp}"
}

# --- Comment limits ---

forge_get_comment_max_len() {
  echo "65000"
}

# --- Labels ---

forge_create_label() {
  local repo="$1" name="$2" description="$3" color="$4"
  gh label create "${name}" --repo "${repo}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

# --- Issues ---

forge_create_issue() {
  local repo="$1" title="$2" body="$3" label="$4"
  gh issue create \
    --repo "${repo}" \
    --title "${title}" \
    --body "${body}" \
    --label "${label}" 2>&1
}

# --- Comments ---

forge_post_comment() {
  local repo="$1" number="$2" body="$3"
  jq -nc --arg body "${body}" '{body: $body}' | gh api \
    "repos/${repo}/issues/${number}/comments" \
    --input - 2>&1
}
# END bundled: lib/github-retro-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-retro-ops.lib.sh
# shellcheck shell=bash
# gitlab-retro-ops.lib.sh — GitLab forge operations for retro scripts.
#
# Bundled into pre-retro.sh and post-retro.sh via retro-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by forge_parse_originating_url):
#   GITLAB_HOST             — API host (e.g., "gitlab.com")
#   ORIGINATING_REPO        — plain project path (e.g., "group/project")
#   ORIGINATING_NUMBER      — issue IID or MR IID
#   ORIGINATING_RESOURCE    — "issues" or "merge_requests"
#
# Expected env vars:
#   ORIGINATING_URL — HTML URL of the originating MR or issue
#   GITLAB_TOKEN    — GitLab personal/project access token

[[ -n "${GITLAB_RETRO_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_RETRO_OPS_SH_LOADED=1

# shellcheck source=gitlab-host-validation.lib.sh
# BEGIN bundled: lib/gitlab-host-validation.lib.sh
# shellcheck shell=bash
# gitlab-host-validation.lib.sh — Shared host validation for GitLab ops.
#
# Validates a hostname against CI_SERVER_HOST, a GitLab CI predefined
# variable set automatically by the runner.
#
# Fails closed: rejects when CI_SERVER_HOST is not set.
#
# Sourced by all gitlab-*-ops.lib.sh files and inlined by the bundler.

[[ -n "${GITLAB_HOST_VALIDATION_SH_LOADED:-}" ]] && return 0
GITLAB_HOST_VALIDATION_SH_LOADED=1

if ! declare -F _gha_sanitize >/dev/null 2>&1; then
  _gha_sanitize() {
    printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'
  }
fi

_validate_gitlab_host() {
  local host="$1"
  if [[ -z "${CI_SERVER_HOST:-}" ]]; then
    echo "ERROR: CI_SERVER_HOST is not set (set by GitLab CI runner)" >&2
    return 1
  fi
  if [[ ! "${CI_SERVER_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: CI_SERVER_HOST contains invalid characters" >&2
    return 1
  fi
  if [[ "${host,,}" != "${CI_SERVER_HOST,,}" ]]; then
    echo "ERROR: GitLab host '$(_gha_sanitize "${host}")' does not match CI_SERVER_HOST" >&2
    return 1
  fi
}
# END bundled: lib/gitlab-host-validation.lib.sh

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call forge_parse_originating_url first" >&2
    return 1
  fi
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@"
}

# --- URL handling ---

forge_validate_originating_url() {
  if [[ ! "${ORIGINATING_URL}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+){2,}/-/(issues|merge_requests)/[0-9]+$ ]]; then
    echo "ERROR: ORIGINATING_URL does not match expected GitLab pattern: $(_gha_sanitize "${ORIGINATING_URL}")" >&2
    return 1
  fi
  local host
  host=$(echo "${ORIGINATING_URL}" | sed -E 's#^https://([^/:]+)/.*#\1#')
  _validate_gitlab_host "${host}" || return 1
}

forge_parse_originating_url() {
  # Extract host, project path, resource type, and number from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/issues/42
  # e.g., https://gitlab.com/group/project/-/merge_requests/10
  # shellcheck disable=SC2034 # GITLAB_HOST consumed by _gitlab_api and callers
  GITLAB_HOST=$(echo "${ORIGINATING_URL}" | sed -E 's#^https://([^/:]+)/.*#\1#')
  # shellcheck disable=SC2034 # ORIGINATING_REPO consumed by callers and is_target_allowed
  ORIGINATING_REPO=$(echo "${ORIGINATING_URL}" | sed -E 's#^https://[^/]+/(.+)/-/(issues|merge_requests)/[0-9]+$#\1#')
  # shellcheck disable=SC2034 # ORIGINATING_NUMBER consumed by callers after function returns
  ORIGINATING_NUMBER=$(basename "${ORIGINATING_URL}")
  # Detect resource type: issues or merge_requests
  if [[ "${ORIGINATING_URL}" == *"/-/merge_requests/"* ]]; then
    # shellcheck disable=SC2034 # ORIGINATING_RESOURCE consumed by forge_post_comment
    ORIGINATING_RESOURCE="merge_requests"
  else
    # shellcheck disable=SC2034 # ORIGINATING_RESOURCE consumed by forge_post_comment
    ORIGINATING_RESOURCE="issues"
  fi
}

# --- Token handling ---

forge_mask_token() {
  # ::add-mask:: is GHA-only; on non-GHA runners the echo would leak the token.
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::add-mask::${GITLAB_TOKEN}"
  fi
}

forge_require_token() {
  : "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
}

# --- Config workspace ---

forge_get_config_workspace() {
  echo "${CI_PROJECT_DIR:-/tmp}"
}

# --- Comment limits ---

forge_get_comment_max_len() {
  echo "1000000"
}

# --- Labels ---

forge_create_label() {
  local repo="$1" name="$2" description="$3" color="$4"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api POST "/projects/${repo_encoded}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${color}" > /dev/null 2>/dev/null || true
}

# --- Issues ---

forge_create_issue() {
  local repo="$1" title="$2" body="$3" label="$4"
  local repo_encoded body_file
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  printf '%s' "${body}" > "${body_file}"
  local response
  response=$(_gitlab_api POST "/projects/${repo_encoded}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description@${body_file}" \
    --data-urlencode "labels=${label}" 2>&1) || {
    rm -f "${body_file}"
    echo "GitLab API error: issue creation failed in ${repo}: $(_gha_sanitize "${response}")"
    return 1
  }
  rm -f "${body_file}"
  local url
  url=$(echo "${response}" | jq -r '.web_url')
  if [[ -z "${url}" || "${url}" == "null" ]]; then
    echo "GitLab API error: unexpected response from issue creation in ${repo}"
    return 1
  fi
  echo "${url}"
}

# --- Comments ---

# Requires ORIGINATING_RESOURCE (set by forge_parse_originating_url) to
# resolve the correct GitLab notes endpoint (merge_requests vs issues).
forge_post_comment() {
  : "${ORIGINATING_RESOURCE:?forge_parse_originating_url must be called before forge_post_comment}"
  local repo="$1" number="$2" body="$3"
  local repo_encoded body_file rc=0
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  printf '%s' "${body}" > "${body_file}"
  _gitlab_api POST "/projects/${repo_encoded}/${ORIGINATING_RESOURCE}/${number}/notes" \
    --data-urlencode "body@${body_file}" 2>&1 || rc=$?
  rm -f "${body_file}"
  return "${rc}"
}
# END bundled: lib/gitlab-retro-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — set FULLSEND_FORGE to github or gitlab" >&2
    exit 1
    ;;
esac
# END bundled: lib/retro-ops.lib.sh

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
