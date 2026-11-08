#!/usr/bin/env bash
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
# Writes only the five RICE number custom fields, resolved by exact name:
#   RICE Reach, RICE Impact, RICE Confidence, RICE Effort, RICE Score
# Never writes Rank, Priority, status, assignee, or any other Jira field.
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
#   JIRA_API_URL    — optional REST base (api gateway). When unset, read
#                     tracker.jira.api_url from ${FULLSEND_DIR}/config.yaml,
#                     then fall back to JIRA_BASE_URL. Sandbox host files do
#                     not reach host-side post-prioritize.sh.

[[ -n "${JIRA_PRIORITIZE_OPS_SH_LOADED:-}" ]] && return 0
JIRA_PRIORITIZE_OPS_SH_LOADED=1

# shellcheck source=jira-auth.lib.sh
source "${SCRIPT_DIR}/lib/jira-auth.lib.sh"

if [[ -n "${JIRA_API_URL:-}" && "${JIRA_API_URL}" != https://* ]]; then
  echo "ERROR: JIRA_API_URL must start with https://" >&2
  exit 1
fi

_jira_require_vars() {
  if [[ -z "${JIRA_BASE_URL:-}" ]]; then
    echo "ERROR: JIRA_BASE_URL is not set" >&2
    return 1
  fi
}

# REST base: JIRA_API_URL, else tracker.jira.api_url in FULLSEND_DIR/config.yaml,
# else JIRA_BASE_URL. Trailing slashes stripped. Non-https values fail closed.
_jira_api_base() {
  local base cfg url
  base="${JIRA_API_URL:-}"
  base="${base#"${base%%[![:space:]]*}"}"
  base="${base%"${base##*[![:space:]]}"}"
  if [[ -z "${base}" && -n "${FULLSEND_DIR:-}" ]]; then
    cfg="${FULLSEND_DIR}/config.yaml"
    if [[ -f "${cfg}" ]] && command -v yq &>/dev/null; then
      url=$(yq -r '.tracker.jira.api_url // ""' "${cfg}" 2>/dev/null) || url=""
      url="${url#"${url%%[![:space:]]*}"}"
      url="${url%"${url##*[![:space:]]}"}"
      base="${url}"
    fi
  fi
  if [[ -z "${base}" ]]; then
    base="${JIRA_BASE_URL}"
  fi
  if [[ -n "${base}" && "${base}" != https://* ]]; then
    echo "ERROR: Jira REST base must be https, got: ${base}" >&2
    return 1
  fi
  while [[ "${base}" == */ ]]; do
    base="${base%/}"
  done
  printf '%s\n' "${base}"
}

_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift

  _jira_require_vars || return 1
  local api_base
  api_base=$(_jira_api_base) || return 1

  jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" \
    --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --request "${method}" \
    "${api_base}/rest/api/3${endpoint}" \
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

# Resolve one RICE field by exact name. Fail closed unless it is a unique
# customfield_[0-9]+ number field — never Rank, Priority, or system fields.
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
    echo "ERROR: Jira field '${name}' not found or not unique (matches=${count}). Create the five RICE number fields (RICE Reach, RICE Impact, RICE Confidence, RICE Effort, RICE Score) before running prioritize on Jira." >&2
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
  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    if [[ ! "${key}" =~ ^customfield_[0-9]+$ ]]; then
      echo "ERROR: refusing to write non-custom Jira field '${key}'" >&2
      return 1
    fi
  done <<< "${keys}"
}

# --- Project / issue field operations ---

forge_update_project_scores() {
  : "${JIRA_TOKEN:?JIRA_TOKEN must be set}"
  local reach="$1"
  local impact="$2"
  local confidence="$3"
  local effort="$4"
  local score="$5"

  if [[ -z "${ISSUE_NUMBER:-}" ]]; then
    echo "ERROR: ISSUE_NUMBER is not set — call forge_parse_issue_url first" >&2
    return 1
  fi

  local fields_json
  fields_json=$(_jira_api GET "/field") || {
    echo "ERROR: failed to list Jira fields while resolving RICE custom fields" >&2
    return 1
  }

  local reach_id impact_id confidence_id effort_id score_id
  reach_id=$(_jira_custom_number_field_id "${fields_json}" "RICE Reach") || return 1
  impact_id=$(_jira_custom_number_field_id "${fields_json}" "RICE Impact") || return 1
  confidence_id=$(_jira_custom_number_field_id "${fields_json}" "RICE Confidence") || return 1
  effort_id=$(_jira_custom_number_field_id "${fields_json}" "RICE Effort") || return 1
  score_id=$(_jira_custom_number_field_id "${fields_json}" "RICE Score") || return 1

  local payload
  payload=$(jq -n \
    --arg rid "${reach_id}" --argjson r "${reach}" \
    --arg iid "${impact_id}" --argjson i "${impact}" \
    --arg cid "${confidence_id}" --argjson c "${confidence}" \
    --arg eid "${effort_id}" --argjson e "${effort}" \
    --arg sid "${score_id}" --argjson s "${score}" \
    '{fields: {($rid): $r, ($iid): $i, ($cid): $c, ($eid): $e, ($sid): $s}}') || {
    echo "ERROR: failed to build Jira RICE field payload" >&2
    return 1
  }

  _jira_assert_rice_only_payload "${payload}" || return 1

  echo "Writing RICE scores to Jira fields on ${ISSUE_NUMBER}..."
  if ! _jira_api PUT "/issue/${ISSUE_NUMBER}" --data "${payload}" >/dev/null; then
    echo "ERROR: failed to write RICE fields on ${ISSUE_NUMBER} via PUT /issue/${ISSUE_NUMBER}" >&2
    return 1
  fi
  echo "Jira RICE fields updated."
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
