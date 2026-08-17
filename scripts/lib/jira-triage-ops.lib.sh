#!/usr/bin/env bash
# shellcheck shell=bash
# jira-triage-ops.lib.sh — Jira Cloud tracker operations for triage scripts.
#
# Bundled into pre-triage.sh and post-triage.sh via triage-ops.lib.sh.
# Labels, transitions, and cross-project issue creation use curl against
# the Jira Cloud REST API v3. Comment posting shells out to
# `fullsend issues post-comment --tracker jira`, which handles Jira's
# markdown-to-ADF conversion and marker-based find-and-update semantics
# that raw REST calls would otherwise have to reimplement.
#
# Jira Cloud only (v1): the issue host must match *.atlassian.net. Jira
# Server/Data Center is not supported.
#
# Expected globals (set by tracker_parse_issue_url):
#   REPO           — Jira project key (e.g., "PROJ")
#   ISSUE_NUMBER   — full Jira issue key (e.g., "PROJ-123")
#   JIRA_ISSUE_NUM — numeric issue suffix (e.g., "123"), for the
#                    `fullsend issues` CLI's --number flag
#   JIRA_BASE_URL  — Jira instance base URL (e.g., "https://myteam.atlassian.net")
#
# Expected env vars:
#   ISSUE_URL       — HTML URL of the issue (https://<host>.atlassian.net/browse/PROJ-123)
#   JIRA_USER_EMAIL — Jira account email for Basic auth
#   JIRA_TOKEN      — Jira Cloud API token
#
# These are the same env var names the `fullsend issues` CLI commands read
# by default (see `fullsend issues post-comment --help`) — using the same
# names here means one set of credentials covers both the raw REST calls
# in this file and the `fullsend` shell-outs below.
#
# Optional env vars:
#   JIRA_DUPLICATE_TRANSITION   — transition name for the "duplicate" action
#   JIRA_NOT_PLANNED_TRANSITION — transition name for the "not planned" action
#   JIRA_SPLIT_TRANSITION       — transition name for the "split" action
#   JIRA_CREATE_ISSUE_TYPE      — issue type name for cross-project issue
#                                 creation (default: "Task")

[[ -n "${JIRA_TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
JIRA_TRIAGE_OPS_SH_LOADED=1

_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
    --header "Content-Type: application/json" \
    --request "${method}" \
    "${JIRA_BASE_URL}/rest/api/3${endpoint}" \
    "$@"
}

_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file
  err_file=$(mktemp)
  local raw
  raw=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
    --header "Content-Type: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${JIRA_BASE_URL}/rest/api/3${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "Jira API error: curl failed — $(cat "${err_file}")" >&2
    rm -f "${err_file}"
    return 1
  }
  rm -f "${err_file}"
  local http_code
  http_code=$(echo "${raw}" | tail -1)
  local body
  body=$(echo "${raw}" | sed '$d')
  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    echo "Jira API error (HTTP ${http_code}): ${body}" >&2
    return 1
  fi
  echo "${body}"
}

# --- URL handling ---

tracker_validate_issue_url() {
  if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected Jira pattern: ${ISSUE_URL}" >&2
    return 1
  fi
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  case "${host}" in
    *.atlassian.net) ;;
    *) echo "ERROR: Jira host '${host}' is not in the allowed host list" >&2; return 1 ;;
  esac
}

tracker_parse_issue_url() {
  local host
  host=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
  local parsed_base_url="https://${host}"
  if [[ -n "${JIRA_BASE_URL:-}" ]] && [[ "${JIRA_BASE_URL}" != "${parsed_base_url}" ]]; then
    echo "ERROR: JIRA_BASE_URL ('${JIRA_BASE_URL}') does not match ISSUE_URL host ('${parsed_base_url}') — refusing to redirect API calls to a different tenant" >&2
    return 1
  fi
  JIRA_BASE_URL="${parsed_base_url}"
  ISSUE_NUMBER=$(echo "${ISSUE_URL}" | sed -E 's|.*/browse/||')
  REPO="${ISSUE_NUMBER%-*}"
  JIRA_ISSUE_NUM="${ISSUE_NUMBER##*-}"
}

# --- Labels ---

tracker_add_label() {
  local label="$1"
  if ! _jira_api PUT "/issue/${ISSUE_NUMBER}" \
    --data "$(jq -cn --arg l "${label}" '{update:{labels:[{add:$l}]}}')" > /dev/null; then
    echo "ERROR: failed to add label '${label}' to issue ${ISSUE_NUMBER} via PUT /issue/${ISSUE_NUMBER}" >&2
    return 1
  fi
}

tracker_remove_label() {
  local label="$1"
  _jira_api PUT "/issue/${ISSUE_NUMBER}" \
    --data "$(jq -cn --arg l "${label}" '{update:{labels:[{remove:$l}]}}')" > /dev/null 2>/dev/null || true
}

tracker_strip_labels() {
  local labels=("$@")
  for label in "${labels[@]}"; do
    _jira_api PUT "/issue/${ISSUE_NUMBER}" \
      --data "$(jq -cn --arg l "${label}" '{update:{labels:[{remove:$l}]}}')" > /dev/null 2>/dev/null || true
  done
}

tracker_verify_labels_stripped() {
  local labels=("$@")
  local raw_labels
  raw_labels=$(_jira_api GET "/issue/${ISSUE_NUMBER}?fields=labels" 2>/dev/null) || {
    echo "ERROR: cannot verify label state — API call failed" >&2
    return 1
  }

  local remaining=""
  local current
  while IFS= read -r current; do
    [[ -z "${current}" ]] && continue
    for check in "${labels[@]}"; do
      if [[ "${current}" == "${check}" ]]; then
        if [[ -n "${remaining}" ]]; then
          remaining="${remaining}, ${current}"
        else
          remaining="${current}"
        fi
      fi
    done
  done < <(echo "${raw_labels}" | jq -r '.fields.labels[]' 2>/dev/null)

  if [[ -n "${remaining}" ]]; then
    echo "ERROR: triage labels still present after reset: ${remaining}" >&2
    return 1
  fi
}

# Jira has no per-project label registry like GitHub/GitLab — any string is
# a valid label with no creation step. As the closest analog to "labels the
# maintainers already established" (which the "will not auto-create" guard
# in post-triage.src.sh relies on), this lists labels already used anywhere
# in the Jira site via the global label-suggestion endpoint.
tracker_list_repo_labels() {
  local start_at=0 max_pages=50
  for _ in $(seq 1 "${max_pages}"); do
    local batch
    batch=$(_jira_api GET "/label?startAt=${start_at}&maxResults=200" 2>/dev/null) || break
    local count
    count=$(echo "${batch}" | jq '.values | length') || break
    [[ "${count}" -eq 0 ]] && break
    echo "${batch}" | jq -r '.values[]'
    if [[ "$(echo "${batch}" | jq -r '.isLast')" == "true" ]]; then
      break
    fi
    start_at=$((start_at + count))
  done
}

# Jira has no label-creation step (see tracker_list_repo_labels) — adding an
# unused label to an issue works without registering it first.
tracker_create_label() {
  :
}

# --- Comments ---

tracker_post_comment() {
  local body="$1"
  # `fullsend issues post-comment` always does marker-based find-and-update;
  # there is no "always create new" mode. A marker unique to this invocation
  # guarantees no prior comment matches it, so this always creates a new
  # comment — matching tracker_post_comment's always-new contract on
  # GitHub/GitLab.
  local marker
  marker="<!-- fullsend:triage-$(date +%s%N) -->"
  printf '%s' "${body}" | fullsend issues post-comment --tracker jira \
    --project "${REPO}" --number "${JIRA_ISSUE_NUM}" \
    --jira-url "${JIRA_BASE_URL}" --jira-email "${JIRA_USER_EMAIL}" --token "${JIRA_TOKEN}" \
    --marker "${marker}" --result -
}

tracker_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  printf '%s' "${body}" | fullsend issues post-comment --tracker jira \
    --project "${REPO}" --number "${JIRA_ISSUE_NUM}" \
    --jira-url "${JIRA_BASE_URL}" --jira-email "${JIRA_USER_EMAIL}" --token "${JIRA_TOKEN}" \
    --marker "${marker}" --result -
}

# --- Issues ---

tracker_close_issue() {
  local reason="$1"
  local transition_var
  case "${reason}" in
    duplicate) transition_var="JIRA_DUPLICATE_TRANSITION" ;;
    "not planned") transition_var="JIRA_NOT_PLANNED_TRANSITION" ;;
    completed) transition_var="JIRA_SPLIT_TRANSITION" ;;
    *)
      echo "ERROR: unknown close reason '${reason}' — no Jira transition mapping" >&2
      return 1
      ;;
  esac

  local transition_name="${!transition_var:-}"
  if [[ -z "${transition_name}" ]]; then
    echo "ERROR: ${transition_var} is not set — cannot close issue ${ISSUE_NUMBER} via Jira transition for reason '${reason}'" >&2
    return 1
  fi

  local transitions
  transitions=$(_jira_api GET "/issue/${ISSUE_NUMBER}/transitions" 2>/dev/null) || {
    echo "ERROR: failed to list transitions for issue ${ISSUE_NUMBER}" >&2
    return 1
  }
  local transition_id
  transition_id=$(echo "${transitions}" | jq -r --arg name "${transition_name}" \
    '[.transitions[] | select(.name == $name)][0].id // empty')
  if [[ -z "${transition_id}" ]]; then
    echo "ERROR: transition '${transition_name}' (from ${transition_var}) is not available on issue ${ISSUE_NUMBER}" >&2
    return 1
  fi

  if ! _jira_api POST "/issue/${ISSUE_NUMBER}/transitions" \
    --data "$(jq -cn --arg id "${transition_id}" '{transition:{id:$id}}')" > /dev/null; then
    echo "ERROR: failed to transition issue ${ISSUE_NUMBER} via '${transition_name}'" >&2
    return 1
  fi
}

tracker_create_issue() {
  local target_repo="$1"
  local title="$2"
  local body="$3"
  local issue_type="${JIRA_CREATE_ISSUE_TYPE:-Task}"
  # Jira Cloud REST v3 requires the description as Atlassian Document
  # Format, not plain text/markdown. A single-paragraph doc is sufficient
  # here since prerequisite/sub-issue bodies are plain text.
  local description_adf
  description_adf=$(jq -cn --arg text "${body}" \
    '{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:$text}]}]}')
  local response
  response=$(_jira_api_with_status POST "/issue" \
    --data "$(jq -cn --arg proj "${target_repo}" --arg title "${title}" \
      --arg itype "${issue_type}" --argjson desc "${description_adf}" \
      '{fields:{project:{key:$proj},summary:$title,description:$desc,issuetype:{name:$itype}}}')") || {
    echo "Jira API error: failed to create issue in ${target_repo}" >&2
    return 1
  }
  local key
  key=$(echo "${response}" | jq -r '.key')
  echo "${JIRA_BASE_URL}/browse/${key}"
}
