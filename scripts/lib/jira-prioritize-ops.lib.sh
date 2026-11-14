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
source "${SCRIPT_DIR}/lib/jira-auth.lib.sh"

_jira_require_vars() {
  if [[ -z "${JIRA_BASE_URL:-}" ]]; then
    echo "ERROR: JIRA_BASE_URL is not set" >&2
    return 1
  fi
}

# Print the trimmed string value at a tracker.jira key in
# ${FULLSEND_DIR}/config.yaml. Prints nothing when there is no config file
# or the key is unset. Fails closed (non-zero) when the config file exists
# but cannot be read: yq missing or a yq parse error must not be treated as
# "no config", or Jira writes could be routed to the default gateway.
_jira_config_value() {
  local key="$1" cfg val
  [[ -n "${FULLSEND_DIR:-}" ]] || return 0
  cfg="${FULLSEND_DIR}/config.yaml"
  [[ -f "${cfg}" ]] || return 0
  if ! command -v yq &>/dev/null; then
    echo "ERROR: ${cfg} exists but yq is not installed — cannot read tracker.jira.${key}" >&2
    return 1
  fi
  val=$(yq -r ".tracker.jira.${key} // \"\"" "${cfg}" 2>/dev/null) || {
    echo "ERROR: failed to parse tracker.jira.${key} from ${cfg}" >&2
    return 1
  }
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
  url=$(_jira_config_value api_url) || return 1
  _jira_clean_https_url "REST base" "${url:-https://api.atlassian.com}"
}

# Site URL used for cloud-ID discovery: tracker.jira.base_url when set,
# else JIRA_BASE_URL (already tied to the ISSUE_URL host). It must be the
# tenant that owns the issue, so a config pointing at another site fails
# closed instead of routing writes to a different tenant.
_jira_site_base() {
  local cfg_base site
  _jira_require_vars || return 1
  cfg_base=$(_jira_config_value base_url) || return 1
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
