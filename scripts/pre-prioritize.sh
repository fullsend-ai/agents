#!/usr/bin/env bash
# GENERATED from pre-prioritize.src.sh — DO NOT EDIT. Run: make script-build
# pre-prioritize.sh — Validate the issue URL before the agent runs.
#
# Runs on the host via the harness pre_script mechanism.
#
# Required env vars:
#   ISSUE_URL      — HTML URL of the issue to score
#   FULLSEND_FORGE — "github", "gitlab", or "jira"

set -euo pipefail

: "${ISSUE_URL:?ISSUE_URL must be set}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
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
# Also derives the trusted origin (scheme, host, and optional port) from
# CI_SERVER_URL so self-managed instances on non-default HTTPS ports work.
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

# Prints the trusted GitLab origin (https://host[:port]) for API requests
# and generated links. Derived from CI_SERVER_URL, a GitLab CI predefined
# variable that carries any non-default port; falls back to
# https://${CI_SERVER_HOST} when CI_SERVER_URL is unset. Fails closed when
# the origin is not HTTPS or its host does not match CI_SERVER_HOST.
_gitlab_trusted_origin() {
  _validate_gitlab_host "${CI_SERVER_HOST:-}" || return 1
  local origin="${CI_SERVER_URL:-https://${CI_SERVER_HOST}}"
  if [[ ! "${origin}" =~ ^https://([a-zA-Z0-9._-]+)(:[0-9]+)?$ ]]; then
    echo "ERROR: CI_SERVER_URL is not an HTTPS origin (https://host[:port]): $(_gha_sanitize "${origin}")" >&2
    return 1
  fi
  local host="${BASH_REMATCH[1]}"
  _validate_gitlab_host "${host}" || return 1
  printf '%s\n' "${origin}"
}

# Validates an origin (https://host[:port]) parsed from an untrusted URL
# against the trusted CI server origin. Scheme, host, and port must all
# match: a URL without a port only matches a trusted origin without one.
_validate_gitlab_origin() {
  local origin="$1" trusted
  trusted=$(_gitlab_trusted_origin) || return 1
  if [[ "${origin,,}" != "${trusted,,}" ]]; then
    echo "ERROR: GitLab origin '$(_gha_sanitize "${origin}")' does not match CI server origin '$(_gha_sanitize "${trusted}")'" >&2
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
    echo "ERROR: GITLAB_HOST is not set — call forge_parse_issue_url first" >&2
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
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  _validate_gitlab_host "${host}" || return 1
}

forge_parse_issue_url() {
  # Extract host, project path, and issue IID from URL.
  # e.g., https://gitlab.com/group/subgroup/project/-/issues/42
  GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')
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
  jira)
# BEGIN bundled: lib/jira-prioritize-ops.lib.sh
# shellcheck shell=bash
# jira-prioritize-ops.lib.sh — Jira Cloud forge operations for prioritize.
#
# Bundled into pre-prioritize.sh and post-prioritize.sh via prioritize-ops.lib.sh.
# Field writes use curl against the Jira Cloud REST API v3. Sticky comments
# shell out to `fullsend issues post-comment --tracker jira`.
#
# This forge is dark: GitHub and GitLab /fs-prioritize dispatch is unchanged.
# These functions run only when FULLSEND_FORGE=jira.
#
# Writes only one number custom field, resolved by exact name:
#   RICE PRIORITY SCORE
# The Reach, Impact, Confidence, and Effort scores and their reasoning go in
# the sticky comment, never in separate Jira fields. Never writes Rank,
# Priority, status, assignee, or any other Jira field.
#
# Jira Cloud only (v1): the issue host must match *.atlassian.net.
#
# Expected globals (set by forge_parse_issue_url):
#   REPO           — Jira project key (e.g., "AISDLC")
#   ISSUE_NUMBER   — full Jira issue key (e.g., "AISDLC-8")
#   JIRA_ISSUE_NUM — numeric issue suffix (e.g., "8")
#   JIRA_BASE_URL  — Jira site URL (e.g., "https://redhat.atlassian.net")
#
# Expected env vars:
#   ISSUE_URL       — HTML URL (https://<host>.atlassian.net/browse/KEY)
#   JIRA_TOKEN      — Jira API token (required for field writes and comments)
#   JIRA_USER_EMAIL — optional bot-user email; empty selects Bearer auth
#   FULLSEND_DIR    — .fullsend dir whose config.yaml holds tracker.jira
#
# REST routing mirrors fullsend's Jira Scoped client
# (internal/forge/jira/scoped.go): tracker.jira.api_url is the gateway base
# (default https://api.atlassian.com), the cloud ID is discovered from the
# site at tracker.jira.base_url (<base_url>/_edge/tenant_info), and every
# REST call goes to
#   <api_url>/ex/jira/<cloudId>/rest/api/3/...
# The site must match the ISSUE_URL host, and credentials are never sent to
# the tenant_info lookup. A JIRA_API_URL environment variable is not read
# here: the gateway comes only from tracker.jira in the config, as it does
# for the `fullsend issues` CLI.

[[ -n "${JIRA_PRIORITIZE_OPS_SH_LOADED:-}" ]] && return 0
JIRA_PRIORITIZE_OPS_SH_LOADED=1

# shellcheck source=jira-auth.lib.sh
# BEGIN bundled: lib/jira-auth.lib.sh
# shellcheck shell=bash
# jira-auth.lib.sh — Jira credential-mode selection for host-side scripts.
#
# Shared by the Jira triage and scribe ops libraries and post-code.sh, and
# bundled into each script that sources it. Two credential modes
# (fullsend#9007):
#
#   token + email — bot user: Basic auth with email:token
#   token only    — service account: Bearer auth with the token
#
# An email that is empty or only whitespace counts as absent. A harness
# that maps an unset FULLSEND_JIRA_EMAIL to JIRA_USER_EMAIL yields an empty
# string, and that must select Bearer, never an empty-user Basic header.
#
# Every helper takes the token and email as arguments, so callers that
# withhold the credentials from their environment can pass saved copies.

[[ -n "${JIRA_AUTH_SH_LOADED:-}" ]] && return 0
JIRA_AUTH_SH_LOADED=1

# Print the email with surrounding whitespace removed. Empty output means
# no email, which selects Bearer auth.
#
# Usage: jira_auth_email <email>
jira_auth_email() {
  local email="$1"
  email="${email#"${email%%[![:space:]]*}"}"
  email="${email%"${email##*[![:space:]]}"}"
  printf '%s' "${email}"
}

# Run curl with the Authorization for the selected mode, followed by the
# caller's arguments. Fails without calling curl when the token is empty.
#
# Usage: jira_auth_curl <token> <email> [curl args...]
jira_auth_curl() {
  local token="$1"
  local email
  email="$(jira_auth_email "$2")"
  shift 2
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    curl --user "${email}:${token}" "$@"
  else
    curl --oauth2-bearer "${token}" "$@"
  fi
}

# Run the fullsend CLI with the Jira credentials it reads from its
# environment: FULLSEND_JIRA_TOKEN always, FULLSEND_JIRA_EMAIL only for a
# bot user. In Bearer mode an inherited FULLSEND_JIRA_EMAIL is removed, so
# the CLI cannot pick Basic auth. The values go through the environment,
# never the command line.
#
# Usage: jira_auth_fullsend <fullsend-bin> <token> <email> [cli args...]
jira_auth_fullsend() {
  local bin="$1"
  local token="$2"
  local email
  email="$(jira_auth_email "$3")"
  shift 3
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    FULLSEND_JIRA_TOKEN="${token}" FULLSEND_JIRA_EMAIL="${email}" "${bin}" "$@"
  else
    (
      unset FULLSEND_JIRA_EMAIL
      FULLSEND_JIRA_TOKEN="${token}" "${bin}" "$@"
    )
  fi
}
# END bundled: lib/jira-auth.lib.sh

_jira_require_vars() {
  if [[ -z "${JIRA_BASE_URL:-}" ]]; then
    echo "ERROR: JIRA_BASE_URL is not set" >&2
    return 1
  fi
}

# Print the trimmed string value at a tracker.jira key in
# ${FULLSEND_DIR}/config.yaml, or nothing when unavailable.
_jira_config_value() {
  local key="$1" cfg val
  [[ -n "${FULLSEND_DIR:-}" ]] || return 0
  cfg="${FULLSEND_DIR}/config.yaml"
  [[ -f "${cfg}" ]] && command -v yq &>/dev/null || return 0
  val=$(yq -r ".tracker.jira.${key} // \"\"" "${cfg}" 2>/dev/null) || val=""
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "${val}"
}

# Validate an https URL that credentials or lookups will be sent to: no
# userinfo, query, fragment, or whitespace. Trailing slashes are stripped.
_jira_clean_https_url() {
  local what="$1" url="$2"
  while [[ "${url}" == */ ]]; do
    url="${url%/}"
  done
  if [[ ! "${url}" =~ ^https:// ]]; then
    echo "ERROR: Jira ${what} must be https, got: $(_gha_sanitize "${url}")" >&2
    return 1
  fi
  if [[ ! "${url}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    echo "ERROR: Jira ${what} is not a plain https URL: $(_gha_sanitize "${url}")" >&2
    return 1
  fi
  printf '%s\n' "${url}"
}

# Gateway base: tracker.jira.api_url, default https://api.atlassian.com.
_jira_gateway_base() {
  local url
  url=$(_jira_config_value api_url)
  _jira_clean_https_url "REST base" "${url:-https://api.atlassian.com}"
}

# Site URL used for cloud-ID discovery: tracker.jira.base_url when set,
# else JIRA_BASE_URL (already tied to the ISSUE_URL host). It must be the
# tenant that owns the issue, so a config pointing at another site fails
# closed instead of routing writes to a different tenant.
_jira_site_base() {
  local cfg_base site
  _jira_require_vars || return 1
  cfg_base=$(_jira_config_value base_url)
  if [[ -n "${cfg_base}" ]]; then
    cfg_base=$(_jira_clean_https_url "tracker.jira.base_url" "${cfg_base}") || return 1
    if [[ "${cfg_base}" != "${JIRA_BASE_URL}" ]]; then
      echo "ERROR: tracker.jira.base_url ('$(_gha_sanitize "${cfg_base}")') does not match ISSUE_URL host ('$(_gha_sanitize "${JIRA_BASE_URL}")') — refusing to route Jira calls to a different tenant" >&2
      return 1
    fi
  fi
  site=$(_jira_clean_https_url "site URL" "${JIRA_BASE_URL}") || return 1
  case "${site#https://}" in
    *.atlassian.net) ;;
    *)
      echo "ERROR: Jira site '$(_gha_sanitize "${site}")' is not in the allowed host list" >&2
      return 1
      ;;
  esac
  printf '%s\n' "${site}"
}

# Resolve the site's cloud ID once from <site>/_edge/tenant_info. The
# lookup is unauthenticated and does not follow redirects. The value must
# be a UUID before it is placed in a URL path.
#
# Sets JIRA_CLOUD_ID and JIRA_CLOUD_ID_SITE in the caller's shell (do not
# call it inside $(...), or the cache is lost).
_jira_resolve_cloud_id() {
  local site resp id
  site=$(_jira_site_base) || return 1
  if [[ "${JIRA_CLOUD_ID_SITE:-}" == "${site}" && -n "${JIRA_CLOUD_ID:-}" ]]; then
    return 0
  fi
  resp=$(curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    "${site}/_edge/tenant_info") || {
    echo "ERROR: failed to discover Jira cloud ID from ${site}/_edge/tenant_info" >&2
    return 1
  }
  id=$(printf '%s' "${resp}" | jq -r '.cloudId // empty' 2>/dev/null) || id=""
  if [[ ! "${id}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "ERROR: Jira cloud ID discovery from ${site} returned no valid cloudId" >&2
    return 1
  fi
  JIRA_CLOUD_ID="${id}"
  JIRA_CLOUD_ID_SITE="${site}"
}

# REST calls go to <api_url>/ex/jira/<cloudId>/rest/api/3<endpoint>.
_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift

  local gateway rest_root
  gateway=$(_jira_gateway_base) || return 1
  _jira_resolve_cloud_id || return 1
  rest_root="${gateway}/ex/jira/${JIRA_CLOUD_ID}/rest/api/3"

  jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --request "${method}" \
    "${rest_root}${endpoint}" \
    "$@"
}

# --- URL handling ---

forge_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected Jira pattern: $(_gha_sanitize "${ISSUE_URL}")" >&2
    return 1
  fi
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  case "${host}" in
    *.atlassian.net) ;;
    *)
      echo "ERROR: Jira host '$(_gha_sanitize "${host}")' is not in the allowed host list" >&2
      return 1
      ;;
  esac
}

forge_parse_issue_url() {
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  local parsed_base_url="https://${host}"
  while [[ -n "${JIRA_BASE_URL:-}" && "${JIRA_BASE_URL}" == */ ]]; do
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"
  done
  if [[ -n "${JIRA_BASE_URL:-}" ]] && [[ "${JIRA_BASE_URL}" != "${parsed_base_url}" ]]; then
    echo "ERROR: JIRA_BASE_URL ('$(_gha_sanitize "${JIRA_BASE_URL}")') does not match ISSUE_URL host ('$(_gha_sanitize "${parsed_base_url}")') — refusing to redirect API calls to a different tenant" >&2
    return 1
  fi
  JIRA_BASE_URL="${parsed_base_url}"
  ISSUE_NUMBER=$(echo "${ISSUE_URL}" | sed -E 's|.*/browse/||')
  REPO="${ISSUE_NUMBER%-*}"
  JIRA_ISSUE_NUM="${ISSUE_NUMBER##*-}"
}

# Resolve the RICE PRIORITY SCORE field by exact name. Fail closed unless it
# is a unique customfield_[0-9]+ number field — never Rank, Priority, or
# system fields.
_jira_custom_number_field_id() {
  local fields_json="$1"
  local name="$2"
  local matches count id type
  matches=$(echo "${fields_json}" | jq -c --arg n "${name}" '[.[] | select(.name == $n)]') || {
    echo "ERROR: failed to parse Jira field list while looking up '${name}'" >&2
    return 1
  }
  count=$(echo "${matches}" | jq 'length')
  if [[ "${count}" -ne 1 ]]; then
    echo "ERROR: Jira field '${name}' not found or not unique (matches=${count}). Create one custom number field named exactly '${name}' before running prioritize on Jira." >&2
    return 1
  fi
  id=$(echo "${matches}" | jq -r '.[0].id // empty')
  type=$(echo "${matches}" | jq -r '.[0].schema.type // empty')
  if [[ ! "${id}" =~ ^customfield_[0-9]+$ ]]; then
    echo "ERROR: Jira field '${name}' resolved to '${id}', which is not a custom number field — refusing to write" >&2
    return 1
  fi
  if [[ "${type}" != "number" ]]; then
    echo "ERROR: Jira field '${name}' (${id}) has schema type '${type}', expected number" >&2
    return 1
  fi
  printf '%s\n' "${id}"
}

_jira_assert_rice_only_payload() {
  local payload="$1"
  local keys key
  if echo "${payload}" | jq -e '
    .fields
    | (has("priority") or has("rank") or has("assignee") or has("status")
       or has("duedate") or has("issuetype") or has("summary")
       or has("description") or has("parent"))
  ' >/dev/null; then
    echo "ERROR: refusing Jira payload that includes Rank, Priority, or other non-RICE fields" >&2
    return 1
  fi
  keys=$(echo "${payload}" | jq -r '.fields | keys[]')
  if [[ "$(echo "${keys}" | grep -c .)" -ne 1 ]]; then
    echo "ERROR: refusing Jira payload that does not contain exactly one field" >&2
    return 1
  fi
  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    if [[ ! "${key}" =~ ^customfield_[0-9]+$ ]]; then
      echo "ERROR: refusing to write non-custom Jira field '${key}'" >&2
      return 1
    fi
  done <<< "${keys}"
}

# --- Project / issue field operations ---

# Reach, impact, confidence, and effort ($1-$4) go in the sticky comment;
# only the computed score ($5) is written to Jira.
forge_update_project_scores() {
  : "${JIRA_TOKEN:?JIRA_TOKEN must be set}"
  local score="$5"

  if [[ -z "${ISSUE_NUMBER:-}" ]]; then
    echo "ERROR: ISSUE_NUMBER is not set — call forge_parse_issue_url first" >&2
    return 1
  fi

  # Validate the gateway, then resolve the cloud ID in this shell so the
  # $(_jira_api ...) calls below reuse the cache.
  _jira_gateway_base >/dev/null || return 1
  _jira_resolve_cloud_id || return 1

  local fields_json
  fields_json=$(_jira_api GET "/field") || {
    echo "ERROR: failed to list Jira fields while resolving the RICE PRIORITY SCORE field" >&2
    return 1
  }

  local score_id
  score_id=$(_jira_custom_number_field_id "${fields_json}" "RICE PRIORITY SCORE") || return 1

  local payload
  payload=$(jq -n --arg sid "${score_id}" --argjson s "${score}" \
    '{fields: {($sid): $s}}') || {
    echo "ERROR: failed to build Jira RICE field payload" >&2
    return 1
  }

  _jira_assert_rice_only_payload "${payload}" || return 1

  echo "Writing RICE PRIORITY SCORE to Jira field ${score_id} on ${ISSUE_NUMBER}..."
  if ! _jira_api PUT "/issue/${ISSUE_NUMBER}" --data "${payload}" >/dev/null; then
    echo "ERROR: failed to write RICE PRIORITY SCORE on ${ISSUE_NUMBER} via PUT /issue/${ISSUE_NUMBER}" >&2
    return 1
  fi
  echo "Jira RICE PRIORITY SCORE updated."
}

# --- Comments ---

forge_post_sticky_comment() {
  : "${JIRA_TOKEN:?JIRA_TOKEN must be set}"
  local body="$1"
  local marker="$2"
  _jira_require_vars || return 1
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${REPO}" --number "${JIRA_ISSUE_NUM}" \
    --marker "${marker}" --result -
}
# END bundled: lib/jira-prioritize-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab|jira> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/prioritize-ops.lib.sh

forge_validate_issue_url
echo "::notice::🔗 Prioritize target: $(_gha_sanitize "${ISSUE_URL}")"

echo "Issue URL validated."
