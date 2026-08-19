#!/usr/bin/env bash
# GENERATED from post-prioritize.src.sh — DO NOT EDIT. Run: make script-build
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
# BEGIN bundled: lib/prioritize-ops.lib.sh
# shellcheck shell=bash
# prioritize-ops.lib.sh — Forge-dispatch wrapper for prioritize operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${PRIORITIZE_OPS_SH_LOADED:-}" ]] && return 0
PRIORITIZE_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-prioritize-ops.lib.sh
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
# BEGIN bundled: lib/github-api-csma.lib.sh
# github-api-csma.lib.sh — CSMA/CD-style resilience for GitHub API calls via gh/fullsend.
#
# Source from post-prioritize.src.sh:
#   source "${SCRIPT_DIR}/lib/github-api-csma.lib.sh"
#
# Environment (all optional):
#   GITHUB_CSMA_MAX_ATTEMPTS          — default 8
#   GITHUB_CSMA_MIN_REMAINING_CORE    — default 100
#   GITHUB_CSMA_MIN_REMAINING_GRAPHQL — default 100
#   GITHUB_CSMA_SLOT_MIN_MS           — default 250
#   GITHUB_CSMA_SLOT_MAX_MS           — default 750 (0 disables jitter)
#   GITHUB_CSMA_SPREAD_MAX_SEC        — default 60 (post-reset desync spread)
#   GITHUB_CSMA_BACKOFF_CAP_SEC       — default 120

# shellcheck shell=bash

[[ -n "${GITHUB_API_CSMA_SH_LOADED:-}" ]] && return 0
GITHUB_API_CSMA_SH_LOADED=1

_github_csma_max_attempts() {
  echo "${GITHUB_CSMA_MAX_ATTEMPTS:-8}"
}

_github_csma_min_remaining() {
  local resource="$1"
  case "${resource}" in
    graphql) echo "${GITHUB_CSMA_MIN_REMAINING_GRAPHQL:-100}" ;;
    *) echo "${GITHUB_CSMA_MIN_REMAINING_CORE:-100}" ;;
  esac
}

_github_csma_slot_min_ms() {
  echo "${GITHUB_CSMA_SLOT_MIN_MS:-250}"
}

_github_csma_slot_max_ms() {
  echo "${GITHUB_CSMA_SLOT_MAX_MS:-750}"
}

_github_csma_spread_max_sec() {
  echo "${GITHUB_CSMA_SPREAD_MAX_SEC:-60}"
}

_github_csma_backoff_cap_sec() {
  echo "${GITHUB_CSMA_BACKOFF_CAP_SEC:-120}"
}

# Add a random spread delay after a rate-limit sleep to desynchronize runners.
# Called from both github_csma_sense and _github_csma_sleep_after_rate_limit.
_github_csma_post_reset_spread() {
  local spread_max
  spread_max=$(_github_csma_spread_max_sec)
  if (( spread_max > 0 )); then
    local spread_secs=$(( RANDOM % spread_max ))
    echo "Rate limit reset — spreading ${spread_secs}s to desync from other runners..." >&2
    sleep "${spread_secs}"
  fi
}

_github_csma_emit_failure() {
  printf '%s\n' "$1" >&2
}

# Wait until the named rate_limit resource has enough quota (carrier sense).
# Usage: github_csma_sense [core|graphql] [min_remaining]
github_csma_sense() {
  local resource="${1:-core}"
  local min_remaining="${2:-$(_github_csma_min_remaining "${resource}")}"

  local info remaining reset now wait_secs
  if ! info=$(gh api rate_limit 2>/dev/null); then
    echo "WARNING: github_csma_sense: could not read rate_limit; proceeding" >&2
    return 0
  fi

  remaining=$(echo "${info}" | jq -r --arg r "${resource}" '.resources[$r].remaining // empty')
  reset=$(echo "${info}" | jq -r --arg r "${resource}" '.resources[$r].reset // empty')

  if [[ -z "${remaining}" || "${remaining}" == "null" ]]; then
    echo "WARNING: github_csma_sense: no .resources.${resource} in rate_limit; proceeding" >&2
    return 0
  fi

  if (( remaining >= min_remaining )); then
    return 0
  fi

  now=$(date +%s)
  wait_secs=$(( reset - now + 1 ))
  if (( wait_secs < 1 )); then
    wait_secs=1
  fi
  cap=$(_github_csma_backoff_cap_sec)
  if (( wait_secs > cap )); then
    wait_secs="${cap}"
  fi

  echo "Rate limit sense: ${resource} remaining=${remaining} (min=${min_remaining}); waiting ${wait_secs}s until reset..." >&2
  sleep "${wait_secs}"

  # After a rate-limit sleep, all runners wake at the same reset timestamp.
  # Spread them over a wide window to avoid a thundering herd.
  _github_csma_post_reset_spread
}

# Random inter-call delay (slot time) to reduce synchronized collisions.
github_csma_slot() {
  local max_ms min_ms span_ms delay_ms
  max_ms=$(_github_csma_slot_max_ms)
  if (( max_ms <= 0 )); then
    return 0
  fi
  min_ms=$(_github_csma_slot_min_ms)
  if (( min_ms > max_ms )); then
    min_ms="${max_ms}"
  fi
  span_ms=$(( max_ms - min_ms + 1 ))
  delay_ms=$(( min_ms + RANDOM % span_ms ))
  sleep "$(awk -v ms="${delay_ms}" 'BEGIN { printf "%.3f", ms / 1000 }')"
}

# Return 0 if combined output looks like a retryable GitHub rate limit error.
github_csma_is_rate_limit() {
  local text="$1"
  local lower
  lower=$(echo "${text}" | tr '[:upper:]' '[:lower:]')

  if echo "${lower}" | grep -qE 'http 429|status: 429'; then
    return 0
  fi
  if echo "${lower}" | grep -qE 'secondary rate limit|rate limit exceeded|api rate limit'; then
    return 0
  fi
  if echo "${lower}" | grep -qE 'http 403|status: 403'; then
    if echo "${lower}" | grep -qE 'secondary|rate limit|abuse|retry.after'; then
      return 0
    fi
  fi
  return 1
}

# Compute backoff seconds for attempt (0-based). Writes to stdout.
github_csma_backoff() {
  local attempt="$1"
  local cap base delay
  cap=$(_github_csma_backoff_cap_sec)
  base=$(( 1 << attempt ))
  if (( base > cap )); then
    base="${cap}"
  fi
  delay=$(( RANDOM % (base + 1) ))
  if (( delay < 1 )); then
    delay=1
  fi
  echo "${delay}"
}

_github_csma_sleep_after_rate_limit() {
  local attempt="$1"
  local resource="${2:-core}"
  local delay wait_secs now reset info cap

  delay=$(github_csma_backoff "${attempt}")
  if info=$(gh api rate_limit 2>/dev/null); then
    now=$(date +%s)
    reset=$(echo "${info}" | jq -r --arg r "${resource}" '.resources[$r].reset // empty')
    if [[ -n "${reset}" && "${reset}" != "null" ]]; then
      wait_secs=$(( reset - now + 1 ))
      cap=$(_github_csma_backoff_cap_sec)
      if (( wait_secs > cap )); then
        wait_secs="${cap}"
      fi
      if (( wait_secs > delay && wait_secs > 0 )); then
        delay="${wait_secs}"
      fi
    fi
  fi
  echo "GitHub API rate limit (attempt $(( attempt + 1 ))); backing off ${delay}s..." >&2
  sleep "${delay}"

  # After backing off, spread runners to avoid thundering herd on wake.
  _github_csma_post_reset_spread
}

# Run gh with CSMA/CD. First argument: rate_limit resource (core|graphql).
# Remaining arguments are passed to gh. Prints gh stdout on success.
github_csma_run() {
  local resource="${1:-core}"
  shift

  local max_attempts attempt outfile errfile combined
  max_attempts=$(_github_csma_max_attempts)
  outfile=$(mktemp)
  errfile=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '${outfile}' '${errfile}'" RETURN

  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    github_csma_sense "${resource}"
    github_csma_slot

    : >"${outfile}"
    : >"${errfile}"
    local rc=0
    gh "$@" >"${outfile}" 2>"${errfile}" || rc=$?

    combined=$(cat "${outfile}" "${errfile}")
    if github_csma_is_rate_limit "${combined}"; then
      if (( attempt < max_attempts - 1 )); then
        _github_csma_sleep_after_rate_limit "${attempt}" "${resource}"
        continue
      fi
      _github_csma_emit_failure "${combined}"
      return 1
    fi

    if (( rc != 0 )); then
      _github_csma_emit_failure "${combined}"
      return 1
    fi
    cat "${outfile}"
    return 0
  done

  return 1
}

# Run producer | gh with CSMA/CD. First argument: resource; rest are gh args.
# Reads producer output from stdin (save once for retries).
github_csma_run_pipe() {
  local resource="${1:-graphql}"
  shift

  local max_attempts attempt infile outfile errfile combined
  max_attempts=$(_github_csma_max_attempts)
  infile=$(mktemp)
  outfile=$(mktemp)
  errfile=$(mktemp)
  cat >"${infile}"
  # shellcheck disable=SC2064
  trap "rm -f '${infile}' '${outfile}' '${errfile}'" RETURN

  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    github_csma_sense "${resource}"
    github_csma_slot

    : >"${outfile}"
    : >"${errfile}"
    local rc=0
    gh "$@" <"${infile}" >"${outfile}" 2>"${errfile}" || rc=$?

    combined=$(cat "${outfile}" "${errfile}")
    if github_csma_is_rate_limit "${combined}"; then
      if (( attempt < max_attempts - 1 )); then
        _github_csma_sleep_after_rate_limit "${attempt}" "${resource}"
        continue
      fi
      _github_csma_emit_failure "${combined}"
      return 1
    fi

    if (( rc != 0 )); then
      _github_csma_emit_failure "${combined}"
      return 1
    fi
    cat "${outfile}"
    return 0
  done

  return 1
}

# Run an arbitrary command with stdin from caller; retries on rate-limit errors in output.
# First argument: rate_limit resource (core|graphql); remaining args are the command.
github_csma_run_cmd() {
  local resource="${1:-core}"
  shift

  local max_attempts attempt infile outfile errfile combined
  max_attempts=$(_github_csma_max_attempts)
  infile=$(mktemp)
  outfile=$(mktemp)
  errfile=$(mktemp)
  cat >"${infile}"
  # shellcheck disable=SC2064
  trap "rm -f '${infile}' '${outfile}' '${errfile}'" RETURN

  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    github_csma_sense "${resource}"
    github_csma_slot

    : >"${outfile}"
    : >"${errfile}"
    local rc=0
    "$@" <"${infile}" >"${outfile}" 2>"${errfile}" || rc=$?

    combined=$(cat "${outfile}" "${errfile}")
    if github_csma_is_rate_limit "${combined}"; then
      if (( attempt < max_attempts - 1 )); then
        _github_csma_sleep_after_rate_limit "${attempt}" "${resource}"
        continue
      fi
      _github_csma_emit_failure "${combined}"
      return 1
    fi

    if (( rc != 0 )); then
      _github_csma_emit_failure "${combined}"
      return 1
    fi
    cat "${outfile}"
    return 0
  done

  return 1
}
# END bundled: lib/github-api-csma.lib.sh

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
# END bundled: lib/github-prioritize-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-prioritize-ops.lib.sh
# shellcheck shell=bash
# gitlab-prioritize-ops.lib.sh — GitLab forge operations for prioritize scripts.
#
# Bundled into pre-prioritize.sh and post-prioritize.sh via prioritize-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by forge_parse_issue_url):
#   REPO           — plain project path (e.g., "group/project")
#   REPO_ENCODED   — URL-encoded project path (e.g., "group%2Fproject")
#   ISSUE_NUMBER   — issue IID
#   GITLAB_HOST    — API host (e.g., "gitlab.com")
#
# Expected env vars:
#   ISSUE_URL      — HTML URL of the issue
#   GITLAB_TOKEN   — GitLab personal/project access token

[[ -n "${GITLAB_PRIORITIZE_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_PRIORITIZE_OPS_SH_LOADED=1

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call forge_parse_issue_url first" >&2
    return 1
  fi
  case "${GITLAB_HOST}" in
    gitlab.com|gitlab.cee.redhat.com) ;;
    *) echo "ERROR: GITLAB_HOST '$(_gha_sanitize "${GITLAB_HOST}")' is not in the allowed host list" >&2; return 1 ;;
  esac
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@"
}

_GITLAB_BOT_USERNAME=""

_gitlab_bot_username() {
  if [[ -z "${_GITLAB_BOT_USERNAME}" ]]; then
    _GITLAB_BOT_USERNAME=$(_gitlab_api GET "/user" 2>/dev/null | jq -r '.username // empty')
    if [[ -z "${_GITLAB_BOT_USERNAME}" ]]; then
      echo "ERROR: failed to determine GitLab token owner via GET /user" >&2
      return 1
    fi
  fi
  echo "${_GITLAB_BOT_USERNAME}"
}

# --- URL handling ---

forge_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+/-/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitLab pattern: $(_gha_sanitize "${ISSUE_URL}")" >&2
    return 1
  fi
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  case "${host}" in
    gitlab.com|gitlab.cee.redhat.com) ;;
    *) echo "ERROR: GitLab host '$(_gha_sanitize "${host}")' is not in the allowed host list" >&2; return 1 ;;
  esac
}

forge_parse_issue_url() {
  # Extract host, project path, and issue IID from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/issues/42
  GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  REPO=$(echo "${ISSUE_URL}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
  REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
  ISSUE_NUMBER=$(basename "${ISSUE_URL}")
}

# --- Project board operations ---

forge_update_project_scores() {
  # GitLab custom fields API integration deferred. The GitLab Issues API
  # ignores unknown top-level keys (returns 200 silently), so writing RICE
  # field names there is a no-op. The correct Custom Fields API requires
  # field IDs resolved at runtime and is only available on Premium/Ultimate.
  # Scores are always available in the reasoning comment.
  echo "::notice::GitLab custom fields not yet implemented — scores are in comment only"
  return 0
}

# --- Comments ---

forge_post_sticky_comment() {
  : "${GITLAB_TOKEN:?GITLAB_TOKEN must be set}"
  local body="$1"
  local marker="$2"
  local marked_body="${marker}
${body}"

  local bot_user
  bot_user=$(_gitlab_bot_username) || {
    echo "::warning::Could not resolve bot username; falling back to non-sticky comment" >&2
    _gitlab_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
      --data-urlencode "body=${marked_body}" > /dev/null \
      || echo "::warning::Failed to post fallback comment" >&2
    return 0
  }

  local notes="[]"
  local page=1 max_pages=50
  while [[ "${page}" -le "${max_pages}" ]]; do
    local batch
    batch=$(_gitlab_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=asc&page=${page}" 2>/dev/null) || break
    local count
    count=$(echo "${batch}" | jq 'length') || break
    [[ "${count}" -eq 0 ]] && break
    notes=$(echo "${notes}" "${batch}" | jq -s 'add')
    page=$((page + 1))
  done

  local match
  match=$(echo "${notes}" | jq --arg marker "${marker}" --arg user "${bot_user}" \
    '[.[] | select(.author.username == $user and (.body | startswith($marker)))][0] // empty')

  local note_id
  note_id=$(echo "${match}" | jq -r '.id // empty')

  if [[ -n "${note_id}" ]]; then
    local old_body
    old_body=$(echo "${match}" | jq -r '.body // empty')
    local stripped_old
    local escaped_marker
    escaped_marker=$(printf '%s' "${marker}" | sed 's/[].[*^$()+?{|\\]/\\&/g; s|/|\\/|g')
    stripped_old=$(echo "${old_body}" | sed "1{/^${escaped_marker}$/d;}")
    if [[ -n "${stripped_old}" ]]; then
      local history
      history=$(printf '\n\n<details>\n<summary>Previous run</summary>\n\n%s\n\n</details>' "${stripped_old}")
      local max_len=60000
      if [[ ${#history} -gt ${max_len} ]]; then
        history="${history:0:${max_len}}
...(truncated)"
      fi
      marked_body="${marked_body}${history}"
    fi
    _gitlab_api PUT "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes/${note_id}" \
      --data-urlencode "body=${marked_body}" > /dev/null \
      || { echo "::warning::Failed to update sticky comment (note ${note_id})" >&2; return 1; }
  else
    _gitlab_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
      --data-urlencode "body=${marked_body}" > /dev/null \
      || { echo "::warning::Failed to post comment" >&2; return 1; }
  fi
}
# END bundled: lib/gitlab-prioritize-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/prioritize-ops.lib.sh

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
