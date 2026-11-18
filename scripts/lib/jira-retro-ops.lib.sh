#!/usr/bin/env bash
# shellcheck shell=bash
# jira-retro-ops.lib.sh — Jira Cloud tracker operations for retro scripts.
#
# Bundled into pre-retro.sh and post-retro.sh via retro-ops.lib.sh, which
# sources this file AFTER the GitHub/GitLab forge library when
# FULLSEND_TRACKER=jira.
#
# Allows retro to run against Jira-originated work items and/or GitHub PRs
# or GitLab MRs associated with Jira work, filing proposal issues into
# an operator-configured Jira project (RETRO_JIRA_PROJECT) with idempotency
# protection and summary comments.
#
# All writes happen host-side in post-retro.sh with operator-provided
# credentials; the sandbox never receives the Jira token.
#
# Jira Cloud only: JIRA_BASE_URL must be https://<site>.atlassian.net.
#
# Expected env vars:
#   JIRA_BASE_URL          — Jira Cloud base URL (https://<site>.atlassian.net)
#   JIRA_TOKEN             — Jira API token. Or, instead of it:
#   FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET — OAuth client
#                            credentials, mutually exclusive with JIRA_TOKEN
#   FULLSEND_DIR           — .fullsend directory whose config.yaml holds
#                            tracker.jira, for fullsend issues shell-outs
#   RETRO_JIRA_PROJECT     — Jira project key for proposal issues (e.g. "PROJ")
#
# Optional env vars:
#   JIRA_USER_EMAIL        — bot-user email. When set, requests use Basic
#                            auth with email and token; when unset or empty,
#                            Bearer auth with a service-account token.
#   JIRA_API_URL           — REST API gateway base URL (trusted Atlassian
#                            gateway or the configured Jira tenant URL).
#   RETRO_JIRA_ISSUE_TYPE  — issue type name for created issues (default: "Task")
#   RETRO_JIRA_LABELS      — comma-separated allowlist of labels that retro may
#                            apply to Jira issues (default: "ready-for-triage")
#   RETRO_JIRA_MAX_PAGES   — maximum pages fetched per paginated Jira read (default: 50)
#   RETRO_MODE             — "all" (default), "summary_only", or "issues_only"

[[ -n "${JIRA_RETRO_OPS_SH_LOADED:-}" ]] && return 0
JIRA_RETRO_OPS_SH_LOADED=1

RETRO_JIRA_PROJECT="${RETRO_JIRA_PROJECT:-${JIRA_PROJECT:-}}"
RETRO_MODE="${RETRO_MODE:-all}"
if [[ "${RETRO_MODE}" != "summary_only" ]]; then
  : "${JIRA_BASE_URL:?JIRA_BASE_URL must be set}"
  : "${RETRO_JIRA_PROJECT:?RETRO_JIRA_PROJECT must be set}"
fi

# shellcheck source=jira-auth.lib.sh
source "${SCRIPT_DIR}/lib/jira-auth.lib.sh"
jira_auth_select "${JIRA_TOKEN:-}" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET || exit 1

if [[ "${RETRO_MODE}" != "summary_only" ]]; then
  if [[ "${JIRA_AUTH_MODE}" == "none" ]]; then
    echo "ERROR: JIRA_TOKEN must be set, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
    exit 1
  fi
  jira_auth_require_api_url || exit 1
fi

if [[ -n "${JIRA_BASE_URL:-}" ]]; then
  while [[ "${JIRA_BASE_URL}" == */ ]]; do
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"
  done
  if [[ ! "${JIRA_BASE_URL}" =~ ^https://[a-zA-Z0-9-]+\.atlassian\.net$ ]]; then
    echo "ERROR: JIRA_BASE_URL must be a Jira Cloud URL (https://<site>.atlassian.net)" >&2
    exit 1
  fi
fi

RETRO_JIRA_API_BASE="${JIRA_API_URL:-${JIRA_BASE_URL:-}}"
if [[ -n "${RETRO_JIRA_API_BASE}" ]]; then
  while [[ "${RETRO_JIRA_API_BASE}" == */ ]]; do
    RETRO_JIRA_API_BASE="${RETRO_JIRA_API_BASE%/}"
  done
  if [[ ! "${RETRO_JIRA_API_BASE}" =~ ^https://api\.atlassian\.com/ex/jira/[A-Za-z0-9-]+$ && "${RETRO_JIRA_API_BASE}" != "${JIRA_BASE_URL:-}" ]]; then
    echo "ERROR: JIRA_API_URL must match JIRA_BASE_URL or the Atlassian API gateway URL (https://api.atlassian.com/ex/jira/<cloudId>)" >&2
    exit 1
  fi
fi

if [[ "${RETRO_MODE}" != "summary_only" ]]; then
  [[ -n "${FULLSEND_DIR:-}" ]] || {
    echo "ERROR: FULLSEND_DIR must be set when FULLSEND_TRACKER=jira" >&2
    exit 1
  }
  config_file="${FULLSEND_DIR}/config.yaml"
  if [[ ! -f "${config_file}" && -f "${FULLSEND_DIR}/config.base.yaml" ]]; then
    config_file="${FULLSEND_DIR}/config.base.yaml"
  fi
  if [[ -f "${config_file}" ]] && command -v yq >/dev/null 2>&1; then
    config_base=$(yq -r '.tracker.jira.base_url // empty' "${config_file}" 2>/dev/null || true)
    config_api=$(yq -r '.tracker.jira.api_url // empty' "${config_file}" 2>/dev/null || true)
    for variable in config_base config_api; do
      while [[ -n "${!variable}" && "${!variable}" == */ ]]; do
        printf -v "${variable}" '%s' "${!variable%/}"
      done
    done
    if [[ -n "${config_base}" && "${config_base}" != "${JIRA_BASE_URL}" ]]; then
      echo "ERROR: JIRA_BASE_URL must match tracker.jira.base_url in ${config_file}" >&2
      exit 1
    fi
    if [[ -n "${config_api}" && "${config_api}" != "${RETRO_JIRA_API_BASE}" ]]; then
      echo "ERROR: JIRA_API_URL must match tracker.jira.api_url in ${config_file}" >&2
      exit 1
    fi
    if [[ -n "${config_base}" && -z "${config_api}" && "${RETRO_JIRA_API_BASE}" != "${JIRA_BASE_URL}" ]]; then
      echo "ERROR: JIRA_API_URL must match tracker.jira.base_url when tracker.jira.api_url is unset" >&2
      exit 1
    fi
  fi
fi

if [[ "${RETRO_MODE}" != "summary_only" && "${JIRA_AUTH_MODE}" == "client" ]]; then
  jira_auth_mint || exit 1
fi

if [[ -n "${RETRO_JIRA_PROJECT}" && ! "${RETRO_JIRA_PROJECT}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
  echo "ERROR: RETRO_JIRA_PROJECT must be a Jira project key (e.g. PROJ)" >&2
  exit 1
fi

RETRO_JIRA_ISSUE_TYPE="${RETRO_JIRA_ISSUE_TYPE:-Task}"
RETRO_JIRA_LABELS="${RETRO_JIRA_LABELS-ready-for-triage}"
RETRO_JIRA_LABELS_CONFIGURED="${RETRO_JIRA_LABELS}"
if [[ -z "${RETRO_JIRA_LABELS}" ]]; then
  echo "INFO: RETRO_JIRA_LABELS is empty — Jira issues will be created without labels" >&2
fi
RETRO_JIRA_MAX_PAGES="${RETRO_JIRA_MAX_PAGES:-50}"

_retro_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    "${RETRO_JIRA_API_BASE}/rest/api/3${endpoint}" \
    "$@"
}

_retro_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file raw http_code body
  err_file=$(mktemp)
  raw=$(jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${RETRO_JIRA_API_BASE}/rest/api/3${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "Jira API error: curl failed — $(_gha_sanitize "$(cat "${err_file}")")" >&2
    rm -f "${err_file}"
    return 1
  }
  rm -f "${err_file}"
  http_code=$(printf '%s' "${raw}" | tail -1)
  body=$(printf '%s' "${raw}" | sed '$d')
  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    local errors
    errors=$(printf '%s' "${body}" | jq -r '(.errorMessages // []) + [(.errors // {} | to_entries[] | "\(.key): \(.value)")] | join("; ")' 2>/dev/null || echo "")
    echo "Jira API error (HTTP ${http_code}): $(_gha_sanitize "${errors:-${body}}")" >&2
    return 1
  fi
  printf '%s' "${body}"
}

_retro_jql_quote() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '"%s"' "${val}"
}

_retro_jira_search_paginated() {
  local jql="$1" fields_json="$2" output_file="$3"
  local token="" page payload response is_last
  : > "${output_file}"
  for ((page = 1; page <= RETRO_JIRA_MAX_PAGES; page++)); do
    payload=$(jq -cn --arg jql "${jql}" --argjson fields "${fields_json}" --arg tok "${token}" \
      '{jql: $jql, fields: $fields, maxResults: 100} + (if $tok != "" then {nextPageToken: $tok} else {} end)')
    response=$(_retro_jira_api POST "/search/jql" --data "${payload}") || {
      echo "ERROR: Jira JQL search failed" >&2
      return 1
    }
    if ! printf '%s' "${response}" | jq -ce 'select(type == "object" and (.issues | type) == "array") | .issues' >> "${output_file}"; then
      echo "ERROR: Jira JQL search returned a malformed or incomplete response" >&2
      return 1
    fi
    token=$(printf '%s' "${response}" | jq -r '.nextPageToken // empty') || {
      echo "ERROR: Jira JQL search response could not be parsed" >&2
      return 1
    }
    is_last=$(printf '%s' "${response}" | jq -r '.isLast // false') || {
      echo "ERROR: Jira JQL search response could not be parsed" >&2
      return 1
    }
    if [[ "${is_last}" == "true" ]]; then
      return 0
    fi
    if [[ -z "${token}" ]]; then
      echo "ERROR: Jira JQL search returned isLast=false with no nextPageToken" >&2
      return 1
    fi
  done
  echo "WARNING: Jira search stopped after ${RETRO_JIRA_MAX_PAGES} pages; results are truncated" >&2
  return 2
}

_retro_jira_filter_labels() {
  local raw="$1"
  jq -cn \
    --arg raw "${raw}" \
    --arg allowlist "${RETRO_JIRA_LABELS_CONFIGURED}" '
    def parse_list:
      if (type == "array") then .
      elif (type == "string") then [split(",")[] | gsub("^\\s+|\\s+$"; "")]
      else [] end;
    def parse_raw:
      ($raw | try fromjson catch $raw) | parse_list;
    def parse_allowlist:
      if $allowlist == "" then [] else $allowlist | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(test("^[A-Za-z0-9._-]{1,64}$"))) end;
    (parse_allowlist) as $allowed |
    [parse_raw[]?
      | select(type == "string")
      | gsub("^\\s+|\\s+$"; "")
      | select(test("^[A-Za-z0-9._-]{1,64}$"))
      | select(. as $item | $allowed | index($item))
    ] | reduce .[] as $item ([]; if index($item) then . else . + [$item] end) | .[0:10]
  '
}

_retro_jira_add_labels() {
  local key="$1" labels="$2"
  local labels_json ops
  if [[ "${RETRO_JIRA_LABELS_CONFIGURED}" == "" ]]; then
    return 0
  fi
  labels_json=$(_retro_jira_filter_labels "${labels}")
  if [[ "$(printf '%s' "${labels_json}" | jq 'length')" -eq 0 ]]; then
    if [[ -n "${labels}" && -n "${RETRO_JIRA_LABELS}" ]]; then
      echo "WARNING: no requested Jira labels are allowed by RETRO_JIRA_LABELS; issue will be created without labels" >&2
    fi
    return 0
  fi
  ops=$(printf '%s' "${labels_json}" | jq '{update:{labels:[.[] | {add:.}]}}')
  _retro_jira_api_with_status PUT "/issue/${key}" --data "${ops}" > /dev/null
}

_retro_jira_createmeta_all() {
  local endpoint="$1" start=0 page resp count total last
  local items_file
  items_file=$(mktemp)
  printf '[]' > "${items_file}"
  for ((page = 1; page <= RETRO_JIRA_MAX_PAGES; page++)); do
    resp=$(_retro_jira_api GET "${endpoint}?maxResults=200&startAt=${start}") || { rm -f "${items_file}"; return 1; }
    count=$(printf '%s' "${resp}" | jq -r '(.issueTypes // .values // .fields // []) | length') || { rm -f "${items_file}"; return 1; }
    if printf '%s' "${resp}" | jq -c '(.issueTypes // .values // .fields // []) | map(del(.allowedValues))' \
      | jq -sc '.[0] + .[1]' "${items_file}" - > "${items_file}.tmp" \
      && mv "${items_file}.tmp" "${items_file}"; then
      :
    else
      rm -f "${items_file}" "${items_file}.tmp"
      return 1
    fi
    total=$(printf '%s' "${resp}" | jq -r '.total // empty')
    last=$(printf '%s' "${resp}" | jq -r 'if has("isLast") then (.isLast | tostring) else "absent" end')
    start=$((start + count))
    if [[ "${count}" -eq 0 || "${last}" == "true" ]] \
      || [[ -z "${total}" && "${last}" == "absent" ]] \
      || [[ -n "${total}" && "${start}" -ge "${total}" ]]; then
      cat "${items_file}"
      rm -f "${items_file}"
      return 0
    fi
  done
  rm -f "${items_file}"
  echo "ERROR: Jira create metadata exceeds ${RETRO_JIRA_MAX_PAGES} pages" >&2
  return 1
}

tracker_validate_create() {
  local types type_id meta missing
  local help_text
  if ! help_text=$(fullsend issues create --help 2>&1) \
    || { [[ "${help_text}" == *"Usage: fullsend issues create"* ]] \
      && [[ "${help_text}" != *"--fullsend-dir"* ]] \
      && [[ "${help_text}" != *"--tracker"* ]]; }; then
    echo "ERROR: installed fullsend does not support 'issues create --tracker jira --fullsend-dir'; upgrade to a version with config-backed Jira issue creation (fullsend#7083 / fullsend#9078)" >&2
    return 1
  fi
  types=$(_retro_jira_createmeta_all "/issue/createmeta/${RETRO_JIRA_PROJECT}/issuetypes") || {
    echo "ERROR: cannot read create metadata for Jira project ${RETRO_JIRA_PROJECT} (missing project or no create permission)" >&2
    return 1
  }
  type_id=$(printf '%s' "${types}" | jq -r --arg name "${RETRO_JIRA_ISSUE_TYPE}" \
    '[.[] | select(.name == $name)][0].id // empty')
  if [[ -z "${type_id}" ]]; then
    echo "ERROR: issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' is not available in Jira project ${RETRO_JIRA_PROJECT}" >&2
    return 1
  fi
  meta=$(_retro_jira_createmeta_all "/issue/createmeta/${RETRO_JIRA_PROJECT}/issuetypes/${type_id}") || {
    echo "ERROR: cannot read create fields for issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' in Jira project ${RETRO_JIRA_PROJECT}" >&2
    return 1
  }
  missing=$(printf '%s' "${meta}" | jq -r '
    [.[]
      | select(.required == true and (.hasDefaultValue // false) == false)
      | select((.fieldId // .key) as $f | ["project","issuetype","summary","description"] | index($f) | not)
      | (.fieldId // .key)] | join(", ")')
  if [[ -n "${missing}" ]]; then
    echo "ERROR: Jira project ${RETRO_JIRA_PROJECT} requires fields retro does not set: $(_gha_sanitize "${missing}")" >&2
    return 1
  fi
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "description")' >/dev/null; then
    echo "ERROR: issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' in Jira project ${RETRO_JIRA_PROJECT} has no Description field on its create screen" >&2
    return 1
  fi
  RETRO_JIRA_LABELS_AVAILABLE=true
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "labels")' >/dev/null; then
    RETRO_JIRA_LABELS_AVAILABLE=false
    echo "WARNING: issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' in Jira project ${RETRO_JIRA_PROJECT} has no Labels field on its create screen; labels will be omitted" >&2
  fi
}

tracker_find_existing_issue() {
  local title="$1" raw_file jql terms match rc=0
  # Drop Jira text-search stop words so they cannot exclude an exact summary.
  # With no usable terms, search the project and compare summaries client-side.
  terms=$(printf '%s' "${title}" | jq -Rs '[scan("[\\p{L}\\p{N}]+") | ascii_downcase] | unique | map(select(length > 2 and (. as $word | (["a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is", "it", "no", "not", "of", "on", "or", "such", "that", "the", "their", "then", "there", "these", "they", "this", "to", "was", "will", "with"] | index($word) | not)))) | sort_by(-length) | .[0:3]') || return 1
  if [[ "$(printf '%s' "${terms}" | jq 'length')" -eq 0 ]]; then
    terms='[]'
  fi
  raw_file=$(mktemp)
  jql=$(printf '%s' "${terms}" | jq -r --arg proj "$(_retro_jql_quote "${RETRO_JIRA_PROJECT}")" '
    ["project = " + $proj] + map("summary ~ \"" + (gsub("\\\\"; "\\\\\\\\") | gsub("\""; "\\\"")) + "\"") | join(" AND ")
  ')
  _retro_jira_search_paginated "${jql}" '["summary"]' "${raw_file}" || rc=$?
  if [[ ${rc} -ne 0 && ${rc} -ne 2 ]]; then
    rm -f "${raw_file}"
    return 1
  fi
  if ! match=$(jq -rs --arg t "${title}" '[.[][] | select(.fields.summary == $t) | .key][0] // empty' "${raw_file}"); then
    rm -f "${raw_file}"
    echo "ERROR: Jira duplicate check could not parse search results" >&2
    return 1
  fi
  rm -f "${raw_file}"
  if [[ -n "${match}" ]]; then
    echo "${JIRA_BASE_URL}/browse/${match}"
  elif [[ ${rc} -eq 2 ]]; then
    echo "ERROR: Jira duplicate check was truncated by the page cap; cannot rule out an existing issue" >&2
    return 1
  fi
}

forge_create_issue() {
  local repo="$1" title="$2" body="$3" labels="${4:-ready-for-triage}"
  if [[ -z "${body}" || "${body}" == "-" ]]; then
    body=$(cat)
  fi
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: forge_create_issue: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  local response key url
  response=$(printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues create \
    --tracker jira \
    --fullsend-dir "${FULLSEND_DIR}" \
    --project "${RETRO_JIRA_PROJECT}" \
    --type "${RETRO_JIRA_ISSUE_TYPE}" \
    --title "${title}" \
    --body -) || {
    echo "ERROR: forge_create_issue: fullsend issues create failed in project ${RETRO_JIRA_PROJECT}" >&2
    return 1
  }
  key=$(printf '%s' "${response}" | jq -r '.key // empty' 2>/dev/null)
  url=$(printf '%s' "${response}" | jq -r '.url // empty' 2>/dev/null)
  if [[ -z "${key}" ]] || [[ ! "${key}" =~ ^${RETRO_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: forge_create_issue: fullsend issues create returned no valid issue key" >&2
    return 1
  fi
  local label_failed=false
  if [[ "${RETRO_JIRA_LABELS_AVAILABLE:-true}" == "true" ]] && [[ -n "${labels}" ]]; then
    if ! _retro_jira_add_labels "${key}" "${labels}"; then
      echo "WARNING: forge_create_issue: failed to add labels to ${key} (issue created without labels)" >&2
      label_failed=true
    fi
  fi
  if [[ -n "${url}" ]]; then
    echo "${url}"
  else
    echo "${JIRA_BASE_URL}/browse/${key}"
  fi
  [[ "${label_failed}" == "true" ]] && return 2
  return 0
}

forge_create_label() {
  # Jira labels are ad-hoc strings and do not require pre-creation.
  return 0
}

forge_issue_url_base() {
  echo "${JIRA_BASE_URL}/browse"
}

forge_normalize_labels() {
  local labels="$1"
  printf '%s' "$(_retro_jira_filter_labels "${labels}")" | jq -r 'join(",")'
}

# --- Originating URL handling and comments ---

forge_validate_originating_url() {
  if [[ "${ORIGINATING_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    local host
    host=$(echo "${ORIGINATING_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
    case "${host}" in
      *.atlassian.net)
        : "${JIRA_BASE_URL:?JIRA_BASE_URL must be set}"
        if [[ "https://${host}" != "${JIRA_BASE_URL}" ]]; then
          echo "ERROR: ORIGINATING_URL Jira host ('${host}') does not match JIRA_BASE_URL ('${JIRA_BASE_URL}')" >&2
          return 1
        fi
        return 0
        ;;
      *)
        echo "ERROR: ORIGINATING_URL Jira host '${host}' is not in the allowed host list (*.atlassian.net)" >&2
        return 1
        ;;
    esac
  fi
  if declare -f _forge_validate_originating_url >/dev/null 2>&1; then
    _forge_validate_originating_url
  else
    echo "ERROR: ORIGINATING_URL does not match expected pattern: $(_gha_sanitize "${ORIGINATING_URL}")" >&2
    return 1
  fi
}

forge_parse_originating_url() {
  if [[ "${ORIGINATING_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    # shellcheck disable=SC2034 # consumed by post-retro
    JIRA_ORIGINATING="true"
    local issue_key
    issue_key=$(echo "${ORIGINATING_URL}" | sed -E 's|.*/browse/||')
    # shellcheck disable=SC2034 # consumed by post-retro
    ORIGINATING_REPO="${issue_key%-*}"
    # shellcheck disable=SC2034 # consumed by post-retro
    ORIGINATING_NUMBER="${issue_key}"
  else
    # shellcheck disable=SC2034 # consumed by post-retro
    JIRA_ORIGINATING="false"
    if declare -f _forge_parse_originating_url >/dev/null 2>&1; then
      _forge_parse_originating_url
    fi
  fi
}

_retro_jira_post_comment() {
  local repo="$1" number="$2" body="$3"
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  if [[ "${JIRA_AUTH_MODE}" == "none" ]]; then
    echo "ERROR: Jira credentials must be set to post comments to Jira" >&2
    return 1
  fi
  # Jira issue keys are <PROJECT>-<NUMBER>; fullsend's --number expects the numeric suffix.
  local num="${number##*-}"
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${repo}" --number "${num}" \
    --marker "<!-- fullsend:retro-agent -->" --result - 2>&1
}

forge_post_comment() {
  local repo="$1" number="$2" body="$3"
  if [[ "${JIRA_ORIGINATING:-false}" == "true" ]]; then
    _retro_jira_post_comment "${repo}" "${number}" "${body}"
  elif declare -f _forge_post_comment >/dev/null 2>&1; then
    _forge_post_comment "${repo}" "${number}" "${body}"
  else
    echo "ERROR: no forge_post_comment defined" >&2
    return 1
  fi
}

forge_require_token() {
  local jira_origin="${JIRA_ORIGINATING:-false}"
  if [[ "${jira_origin}" != "true" && "${ORIGINATING_URL:-}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    jira_origin="true"
  fi
  if [[ "${RETRO_MODE}" != "summary_only" || "${jira_origin}" == "true" ]]; then
    if [[ "${JIRA_AUTH_MODE}" == "none" ]]; then
      echo "ERROR: JIRA_TOKEN must be set, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
      return 1
    fi
  fi
  if [[ "${jira_origin}" == "true" ]]; then
    return 0
  fi
  if declare -f _forge_require_token >/dev/null 2>&1; then
    _forge_require_token
  fi
}

forge_mask_token() {
  local jira_origin="${JIRA_ORIGINATING:-false}"
  if [[ "${jira_origin}" != "true" && "${ORIGINATING_URL:-}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    jira_origin="true"
  fi
  if [[ "${jira_origin}" != "true" ]] && declare -f _forge_mask_token >/dev/null 2>&1; then
    _forge_mask_token
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" && -n "${JIRA_TOKEN:-}" ]]; then
    _gha_mask "${JIRA_TOKEN}"
  fi
}

forge_get_comment_max_len() {
  if [[ "${JIRA_ORIGINATING:-false}" == "true" ]]; then
    echo "32000"
  elif declare -f _forge_get_comment_max_len >/dev/null 2>&1; then
    _forge_get_comment_max_len
  else
    echo "65000"
  fi
}
