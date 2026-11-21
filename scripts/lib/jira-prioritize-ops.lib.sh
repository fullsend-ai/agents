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
# Writes five custom fields, resolved by exact name:
#   Reach, Impact, Effort, RICE Score — number/float
#   Confidence — select list (shared Jira field; not a number)
# GitHub and GitLab /fs-prioritize are unchanged. The sticky comment still
# prints the agent floats and the RICE formula. Confidence is mapped onto
# the select options only for the Jira field write; the mapped label is
# never used to compute RICE Score. Never writes Rank, Priority, status,
# assignee, or any other Jira field.
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
#   JIRA_TOKEN      — Jira API token (token modes), or
#   FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET — OAuth 2.0
#                     client credentials, the alternative to the token.
#                     Exactly one mode: both set fails closed, none fails.
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

# Select the credential mode once, before any Jira REST or `fullsend issues`
# call, the way the triage and scribe libraries do: a token, or the client
# credentials, but never both and never neither. Client credentials mint
# the Bearer access token here, in the script's own shell, so the
# $(_jira_api ...) calls reuse it. A mint failure is fatal: prioritize
# writes nothing without a usable credential. Not called at source time,
# because pre-prioritize bundles this library and only validates the URL.
# The gateway comes from tracker.jira.api_url (default
# https://api.atlassian.com), which accepts minted access tokens, so
# JIRA_API_URL is not required in client-credentials mode.
_jira_auth_init() {
  [[ -n "${_JIRA_PRIORITIZE_AUTH_READY:-}" ]] && return 0
  jira_auth_select "${JIRA_TOKEN:-}" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET || return 1
  if [[ "${JIRA_AUTH_MODE}" == "none" ]]; then
    echo "ERROR: JIRA_TOKEN must be set, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
    return 1
  fi
  jira_auth_mint || return 1
  _JIRA_PRIORITIZE_AUTH_READY=1
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

  jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
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

# Resolve a custom field by exact name and schema type. Another field may
# share the name with a different type (some JIRA instances have a site-wide
# Impact select next to a different Impact number). Uniqueness is among
# matches of the expected type. Never Rank, Priority, or system fields.
_jira_custom_field_id() {
  local fields_json="$1"
  local name="$2"
  local expected_type="$3"
  local named typed count named_count id type found_id found_type
  named=$(echo "${fields_json}" | jq -c --arg n "${name}" '[.[] | select(.name == $n)]') || {
    echo "ERROR: failed to parse Jira field list while looking up '${name}'" >&2
    return 1
  }
  typed=$(echo "${named}" | jq -c --arg t "${expected_type}" '[.[] | select(.schema.type == $t)]') || {
    echo "ERROR: failed to parse Jira field list while looking up '${name}'" >&2
    return 1
  }
  count=$(echo "${typed}" | jq 'length')
  if [[ "${count}" -eq 0 ]]; then
    named_count=$(echo "${named}" | jq 'length')
    if [[ "${named_count}" -eq 0 ]]; then
      echo "ERROR: Jira field '${name}' not found or not unique (matches=0). Create one custom field named exactly '${name}' before running prioritize on Jira." >&2
      return 1
    fi
    found_id=$(echo "${named}" | jq -r '
      ([.[] | select(.id | test("^customfield_[0-9]+$"))] | .[0].id)
      // .[0].id // empty')
    if [[ ! "${found_id}" =~ ^customfield_[0-9]+$ ]]; then
      echo "ERROR: Jira field '${name}' resolved to '${found_id}', which is not a custom field — refusing to write" >&2
      return 1
    fi
    found_type=$(echo "${named}" | jq -r --arg id "${found_id}" \
      '.[] | select(.id == $id) | .schema.type // empty')
    echo "ERROR: Jira field '${name}' (${found_id}) has schema type '${found_type}', expected ${expected_type}" >&2
    return 1
  fi
  if [[ "${count}" -ne 1 ]]; then
    echo "ERROR: Jira field '${name}' not found or not unique (matches=${count}). Create one custom field named exactly '${name}' before running prioritize on Jira." >&2
    return 1
  fi
  id=$(echo "${typed}" | jq -r '.[0].id // empty')
  type=$(echo "${typed}" | jq -r '.[0].schema.type // empty')
  if [[ ! "${id}" =~ ^customfield_[0-9]+$ ]]; then
    echo "ERROR: Jira field '${name}' resolved to '${id}', which is not a custom field — refusing to write" >&2
    return 1
  fi
  if [[ "${type}" != "${expected_type}" ]]; then
    echo "ERROR: Jira field '${name}' (${id}) has schema type '${type}', expected ${expected_type}" >&2
    return 1
  fi
  printf '%s\n' "${id}"
}

_jira_custom_number_field_id() {
  _jira_custom_field_id "$1" "$2" "number"
}

_jira_custom_option_field_id() {
  _jira_custom_field_id "$1" "$2" "option"
}

# Map the agent Confidence float (0.1–1.0) onto the shared Jira select
# options. The agent rubric is Low 0.1–0.3, Medium 0.4–0.6, High 0.7–1.0.
# This label is only written to the Confidence field. RICE Score always
# uses the unmapped float from agent-result.json.
_jira_map_confidence_select() {
  local conf="$1" label
  if ! jq -e 'type == "number"' <<< "${conf}" &>/dev/null; then
    echo "ERROR: Confidence is not a number; cannot map onto the Jira select field" >&2
    return 1
  fi
  label=$(jq -nr --argjson c "${conf}" '
    if $c < 0.4 then "50% (Low)"
    elif $c < 0.7 then "75% (Medium)"
    else "100% (High)"
    end') || {
    echo "ERROR: failed to map Confidence onto the Jira select options" >&2
    return 1
  }
  printf '%s\n' "${label}"
}

_jira_assert_rice_only_payload() {
  local payload="$1"
  local keys key count
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
  count=$(echo "${keys}" | grep -c .)
  if [[ "${count}" -ne 5 ]]; then
    echo "ERROR: refusing Jira payload that does not contain exactly five RICE fields" >&2
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

# $1–$4 are the agent floats (Reach, Impact, Confidence, Effort). $5 is
# RICE Score, already computed from those floats in post-prioritize.src.sh.
# Confidence is mapped onto the Jira select only in this function.
forge_update_project_scores() {
  local reach="$1"
  local impact="$2"
  local confidence="$3"
  local effort="$4"
  local score="$5"

  _jira_auth_init || return 1

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
    echo "ERROR: failed to list Jira fields while resolving the RICE fields" >&2
    return 1
  }

  local reach_id impact_id effort_id score_id conf_id conf_option
  score_id=$(_jira_custom_number_field_id "${fields_json}" "RICE Score") || return 1
  reach_id=$(_jira_custom_number_field_id "${fields_json}" "Reach") || return 1
  impact_id=$(_jira_custom_number_field_id "${fields_json}" "Impact") || return 1
  effort_id=$(_jira_custom_number_field_id "${fields_json}" "Effort") || return 1
  conf_id=$(_jira_custom_option_field_id "${fields_json}" "Confidence") || return 1
  conf_option=$(_jira_map_confidence_select "${confidence}") || return 1

  local payload
  payload=$(jq -n \
    --arg rid "${reach_id}" --argjson r "${reach}" \
    --arg iid "${impact_id}" --argjson i "${impact}" \
    --arg eid "${effort_id}" --argjson e "${effort}" \
    --arg sid "${score_id}" --argjson s "${score}" \
    --arg cid "${conf_id}" --arg copt "${conf_option}" \
    '{fields: {
      ($rid): $r,
      ($iid): $i,
      ($eid): $e,
      ($sid): $s,
      ($cid): {value: $copt}
    }}') || {
    echo "ERROR: failed to build Jira RICE field payload" >&2
    return 1
  }

  _jira_assert_rice_only_payload "${payload}" || return 1

  echo "Writing RICE fields on ${ISSUE_NUMBER} (Confidence select=${conf_option}; RICE Score uses unmapped Confidence ${confidence})..."
  if ! _jira_api PUT "/issue/${ISSUE_NUMBER}" --data "${payload}" >/dev/null; then
    echo "ERROR: failed to write RICE fields on ${ISSUE_NUMBER} via PUT /issue/${ISSUE_NUMBER}" >&2
    return 1
  fi
  echo "Jira RICE fields updated."
}

# --- Comments ---

forge_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  _jira_auth_init || return 1
  _jira_require_vars || return 1
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${REPO}" --number "${JIRA_ISSUE_NUM}" \
    --marker "${marker}" --result -
}
