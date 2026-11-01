#!/usr/bin/env bash
# shellcheck shell=bash
# jira-scribe-ops.lib.sh — Jira Cloud tracker operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh, which
# sources this file AFTER the GitHub/GitLab forge library when
# FULLSEND_TRACKER=jira. The functions below redefine the backlog, closed-issue,
# and write operations (open-issue fetch, backlog filter, closed-issue fetch,
# open count, issue creation, issue URL base) so that backlog matching,
# closed-issue context, and writes target one Jira project, while repo context
# (open PRs, doc index, run URL) keeps coming from the forge.
#
# Scope (MVP): new issues only, in one operator-configured project and
# issue type. Comment writes are not supported — existing_issue is a
# numeric forge issue number and Jira keys need a separate string-key path.
#
# All writes happen host-side in post-scribe.sh with operator-provided
# credentials; the sandbox never receives the Jira token.
#
# Jira Cloud only: JIRA_BASE_URL must be https://<site>.atlassian.net.
#
# Requires fullsend >= the release that ships `fullsend issues create
# --tracker jira` (fullsend#7083 / fullsend#8499). The post-script
# validates this at preflight time via tracker_validate_create.
#
# Expected env vars:
#   JIRA_BASE_URL          — Jira Cloud base URL (https://<site>.atlassian.net)
#   JIRA_USER_EMAIL        — Jira account email for Basic auth
#   JIRA_TOKEN             — Jira Cloud API token
#   SCRIBE_JIRA_PROJECT    — Jira project key that backlog reads and new
#                            issues are scoped to (e.g. "PROJ")
#
# Optional env vars:
#   SCRIBE_JIRA_ISSUE_TYPE — issue type name for created issues (default: "Task")
#   SCRIBE_JIRA_LABELS     — comma-separated allowlist of labels that scribe may
#                            apply to Jira issues (default: "meeting-notes")
#   SCRIBE_JIRA_MAX_PAGES  — maximum pages fetched per paginated Jira read
#                            (default: 50)

[[ -n "${JIRA_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
JIRA_SCRIBE_OPS_SH_LOADED=1

: "${JIRA_USER_EMAIL:?JIRA_USER_EMAIL must be set}"
: "${JIRA_TOKEN:?JIRA_TOKEN must be set}"
: "${JIRA_BASE_URL:?JIRA_BASE_URL must be set}"
: "${SCRIBE_JIRA_PROJECT:?SCRIBE_JIRA_PROJECT must be set}"

while [[ "${JIRA_BASE_URL}" == */ ]]; do
  JIRA_BASE_URL="${JIRA_BASE_URL%/}"
done
if [[ ! "${JIRA_BASE_URL}" =~ ^https://[a-zA-Z0-9-]+\.atlassian\.net$ ]]; then
  echo "ERROR: JIRA_BASE_URL must be a Jira Cloud URL (https://<site>.atlassian.net)" >&2
  exit 1
fi
if [[ ! "${SCRIBE_JIRA_PROJECT}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
  echo "ERROR: SCRIBE_JIRA_PROJECT must be a Jira project key (e.g. PROJ)" >&2
  exit 1
fi
SCRIBE_JIRA_ISSUE_TYPE="${SCRIBE_JIRA_ISSUE_TYPE:-Task}"
SCRIBE_JIRA_LABELS="${SCRIBE_JIRA_LABELS:-meeting-notes}"

# Maximum pages fetched per paginated Jira read (100 issues per JQL page).
SCRIBE_JIRA_MAX_PAGES="${SCRIBE_JIRA_MAX_PAGES:-50}"

_scribe_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    "${JIRA_BASE_URL}/rest/api/3${endpoint}" \
    "$@"
}

# Like _scribe_jira_api but captures the HTTP status code and returns the
# response body even on error, so callers can log field-level rejection
# reasons instead of a generic "failed" message.
_scribe_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file raw http_code body
  err_file=$(mktemp)
  raw=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${JIRA_BASE_URL}/rest/api/3${endpoint}" \
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

# Escape a value for use inside a double-quoted JQL string literal.
_scribe_jql_quote() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '"%s"' "${val}"
}

_scribe_jira_backlog_jql() {
  printf 'project = %s AND statusCategory != Done ORDER BY created DESC' \
    "$(_scribe_jql_quote "${SCRIBE_JIRA_PROJECT}")"
}

_scribe_jira_closed_jql() {
  printf 'project = %s AND statusCategory = Done AND resolved >= -30d ORDER BY resolved DESC' \
    "$(_scribe_jql_quote "${SCRIBE_JIRA_PROJECT}")"
}

# Run a JQL search, following nextPageToken. Writes one JSON array of issues
# per page to output_file (same multi-document shape as `gh api --paginate`).
# Returns 2 if the page cap was hit while more results remained.
_scribe_jira_search_paginated() {
  local jql="$1" fields_json="$2" output_file="$3"
  local token="" page payload response is_last
  : > "${output_file}"
  for ((page = 1; page <= SCRIBE_JIRA_MAX_PAGES; page++)); do
    payload=$(jq -cn --arg jql "${jql}" --argjson fields "${fields_json}" --arg tok "${token}" \
      '{jql: $jql, fields: $fields, maxResults: 100} + (if $tok != "" then {nextPageToken: $tok} else {} end)')
    response=$(_scribe_jira_api POST "/search/jql" --data "${payload}") || {
      echo "ERROR: Jira JQL search failed" >&2
      return 1
    }
    # A 2xx response that is not JSON, or has no issues array, must not be
    # read as "no results" — callers use that to prove a duplicate is absent.
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
  echo "WARNING: Jira search stopped after ${SCRIBE_JIRA_MAX_PAGES} pages; results are truncated" >&2
  return 2
}

# --- Pre-script: backlog ---

forge_fetch_open_issues_raw() {
  local _repo="$1" output_file="$2" rc=0
  _scribe_jira_search_paginated "$(_scribe_jira_backlog_jql)" \
    '["summary","description","labels","status"]' "${output_file}" || rc=$?
  if [[ ${rc} -eq 2 ]]; then
    # shellcheck disable=SC2034 # SCRIBE_BACKLOG_PAGE_CAPPED consumed by pre-scribe
    SCRIBE_BACKLOG_PAGE_CAPPED=true
    return 2
  fi
  return ${rc}
}

# Convert raw Jira issues to the backlog format. Jira issues carry a string
# `key` instead of a numeric `number`; the description (ADF) is flattened
# to plain text and truncated to 500 chars.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq -s --arg base "${JIRA_BASE_URL}" '[.[][] | {
      key,
      title: (.fields.summary // ""),
      body: ([.fields.description | .. | objects | select(.type == "text") | .text] | join(" ")),
      labels: (.fields.labels // []),
      url: ($base + "/browse/" + .key)
    }]' "${raw_file}" \
    | jq '[.[] | .body = (.body[:500] + if (.body | length) > 500 then "…" else "" end)]' \
    > "${backlog_file}"
}

forge_count_paginated_total() {
  local raw_file="$1"
  jq -s '[.[][]] | length' "${raw_file}"
}

# Approximate open-issue count for truncation detection. Returns empty on
# failure so callers fall back to the fetched count.
forge_get_issue_count() {
  local _repo="$1"
  _scribe_jira_api POST "/search/approximate-count" \
    --data "$(jq -cn --arg jql "$(_scribe_jira_backlog_jql)" '{jql: $jql}')" 2>/dev/null \
    | jq -r '.count // empty' 2>/dev/null || echo ""
}

# Fetch recently closed (Done) issues from the Jira project (resolved in the
# last 30 days, up to limit, default 50).
forge_list_closed_issues() {
  local _repo="$1" output_file="$2" limit="${3:-50}"
  [[ "${limit}" =~ ^[1-9][0-9]*$ ]] || limit=50
  [[ "${limit}" -gt 100 ]] && limit=100
  local payload response
  payload=$(jq -cn \
    --arg jql "$(_scribe_jira_closed_jql)" \
    --argjson limit "${limit}" \
    '{jql: $jql, fields: ["summary","labels"], maxResults: $limit}')
  response=$(_scribe_jira_api POST "/search/jql" --data "${payload}" 2>/dev/null) || {
    echo "WARNING: failed to fetch recently closed Jira issues" >&2
    echo '[]' > "${output_file}"
    return 0
  }
  if ! printf '%s' "${response}" | jq --arg base "${JIRA_BASE_URL}" '[.issues[]? | {
      key,
      title: (.fields.summary // ""),
      labels: (.fields.labels // []),
      url: ($base + "/browse/" + .key)
    }]' > "${output_file}" 2>/dev/null; then
    echo "WARNING: failed to parse recently closed Jira issues" >&2
    echo '[]' > "${output_file}"
    return 0
  fi
}

# --- Post-script: issue operations ---

forge_list_issue_comments() {
  echo "ERROR: comments are not supported when FULLSEND_TRACKER=jira" >&2
  return 1
}

forge_post_issue_comment() {
  echo "ERROR: comments are not supported when FULLSEND_TRACKER=jira" >&2
  return 1
}

# Filter and sanitize labels for Jira:
# 1. Accepts either a JSON array or a comma-separated list.
# 2. Intersects with the operator allowlist SCRIBE_JIRA_LABELS (default: "meeting-notes").
# 3. Enforces ^[A-Za-z0-9._-]{1,64}$ per label.
# 4. Caps at 10 labels and deduplicates while preserving order.
_scribe_jira_filter_labels() {
  local raw="$1"
  jq -cn \
    --arg raw "${raw}" \
    --arg allowlist "${SCRIBE_JIRA_LABELS:-meeting-notes}" '
    def parse_list:
      if (type == "array") then .
      elif (type == "string") then [split(",")[] | gsub("^\\s+|\\s+$"; "")]
      else [] end;
    def parse_raw:
      ($raw | try fromjson catch $raw) | parse_list;
    def parse_allowlist:
      $allowlist | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(test("^[A-Za-z0-9._-]{1,64}$")));
    (parse_allowlist) as $allowed |
    [parse_raw[]?
      | select(type == "string")
      | gsub("^\\s+|\\s+$"; "")
      | select(test("^[A-Za-z0-9._-]{1,64}$"))
      | select(. as $item | $allowed | index($item))
    ] | reduce .[] as $item ([]; if index($item) then . else . + [$item] end) | .[0:10]
  '
}

# Add labels to an existing Jira issue via the REST API. Labels can be
# passed as a JSON array or a comma-separated list. Labels are filtered
# through _scribe_jira_filter_labels (allowlist, format, count cap).
_scribe_jira_add_labels() {
  local key="$1" labels="$2"
  local labels_json ops
  labels_json=$(_scribe_jira_filter_labels "${labels}")
  if [[ "$(printf '%s' "${labels_json}" | jq 'length')" -eq 0 ]]; then
    return 0
  fi
  ops=$(printf '%s' "${labels_json}" | jq '{update:{labels:[.[] | {add:.}]}}')
  _scribe_jira_api_with_status PUT "/issue/${key}" --data "${ops}" > /dev/null
}

# Fetch every item of a paginated createmeta endpoint (startAt paging) and
# print them as one JSON array. Fails if a page cannot be read or the page
# cap is hit before the last page, so callers never validate on partial data.
_scribe_jira_createmeta_all() {
  local endpoint="$1" start=0 page resp count total last
  local items_file
  items_file=$(mktemp)
  printf '[]' > "${items_file}"
  for ((page = 1; page <= SCRIBE_JIRA_MAX_PAGES; page++)); do
    resp=$(_scribe_jira_api GET "${endpoint}?maxResults=200&startAt=${start}") || { rm -f "${items_file}"; return 1; }
    count=$(printf '%s' "${resp}" | jq -r '(.issueTypes // .values // .fields // []) | length') || { rm -f "${items_file}"; return 1; }
    # Merge page items via stdin/file to avoid --argjson argument-size limits
    # on projects with large allowedValues lists. Strip allowedValues to
    # reduce accumulated size since it is not needed for validation.
    if printf '%s' "${resp}" | jq -c '(.issueTypes // .values // .fields // []) | map(del(.allowedValues))' \
      | jq -sc '.[0] + .[1]' "${items_file}" - > "${items_file}.tmp" \
      && mv "${items_file}.tmp" "${items_file}"; then
      :
    else
      rm -f "${items_file}" "${items_file}.tmp"
      return 1
    fi
    total=$(printf '%s' "${resp}" | jq -r '.total // empty')
    # Distinguish absent isLast from explicit false: jq's `// empty`
    # converts false to empty, so use has() to detect absence.
    last=$(printf '%s' "${resp}" | jq -r 'if has("isLast") then (.isLast | tostring) else "absent" end')
    start=$((start + count))
    # Without a total or isLast marker the response is a single page.
    if [[ "${count}" -eq 0 || "${last}" == "true" ]] \
      || [[ -z "${total}" && "${last}" == "absent" ]] \
      || [[ -n "${total}" && "${start}" -ge "${total}" ]]; then
      cat "${items_file}"
      rm -f "${items_file}"
      return 0
    fi
  done
  rm -f "${items_file}"
  echo "ERROR: Jira create metadata exceeds ${SCRIBE_JIRA_MAX_PAGES} pages" >&2
  return 1
}

# Check that the configured project and issue type exist and that every
# required create field without a default is one scribe supplies. Fails
# before any create call when the project needs extra fields.
tracker_validate_create() {
  local types type_id meta missing
  # Preflight: verify that the fullsend CLI ships `issues create`.
  # This subcommand was introduced in fullsend#8499 and may not be
  # present in older binaries. Failing here surfaces the problem on
  # dry-run instead of silently passing validation and then exploding
  # on the first live create.
  if ! fullsend issues create --help >/dev/null 2>&1; then
    echo "ERROR: 'fullsend issues create' is not available — upgrade fullsend to a version that includes issues create (fullsend#8499)" >&2
    return 1
  fi
  types=$(_scribe_jira_createmeta_all "/issue/createmeta/${SCRIBE_JIRA_PROJECT}/issuetypes") || {
    echo "ERROR: cannot read create metadata for Jira project ${SCRIBE_JIRA_PROJECT} (missing project or no create permission)" >&2
    return 1
  }
  type_id=$(printf '%s' "${types}" | jq -r --arg name "${SCRIBE_JIRA_ISSUE_TYPE}" \
    '[.[] | select(.name == $name)][0].id // empty')
  if [[ -z "${type_id}" ]]; then
    echo "ERROR: issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' is not available in Jira project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  fi
  meta=$(_scribe_jira_createmeta_all "/issue/createmeta/${SCRIBE_JIRA_PROJECT}/issuetypes/${type_id}") || {
    echo "ERROR: cannot read create fields for issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' in Jira project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  }
  missing=$(printf '%s' "${meta}" | jq -r '
    [.[]
      | select(.required == true and (.hasDefaultValue // false) == false)
      | select((.fieldId // .key) as $f | ["project","issuetype","summary","description"] | index($f) | not)
      | (.fieldId // .key)] | join(", ")')
  if [[ -n "${missing}" ]]; then
    echo "ERROR: Jira project ${SCRIBE_JIRA_PROJECT} requires fields scribe does not set: $(_gha_sanitize "${missing}")" >&2
    return 1
  fi
  # forge_create_issue sends description and labels; Jira rejects the create
  # when a field is not on the create screen. Description carries the issue
  # content, so fail clearly; labels are optional, so omit them instead.
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "description")' >/dev/null; then
    echo "ERROR: issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' in Jira project ${SCRIBE_JIRA_PROJECT} has no Description field on its create screen" >&2
    return 1
  fi
  SCRIBE_JIRA_LABELS_AVAILABLE=true
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "labels")' >/dev/null; then
    SCRIBE_JIRA_LABELS_AVAILABLE=false
    echo "WARNING: issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' in Jira project ${SCRIBE_JIRA_PROJECT} has no Labels field on its create screen; labels will be omitted" >&2
  fi
}

# Rerun protection: print the browse URL of an issue in the configured
# project whose summary exactly matches the title (any status). Paginates
# all matches of the fuzzy JQL summary search before comparing exactly.
# Returns 1 when the lookup cannot prove absence (API failure, no searchable
# terms, or results truncated by the page cap with no exact match) so callers
# refuse to create blindly.
tracker_find_existing_issue() {
  local title="$1" raw_file jql terms match rc=0
  # JQL text search reserves most punctuation; search on the letter/digit
  # terms only (Unicode-aware) and compare the full title exactly below.
  terms=$(printf '%s' "${title}" | jq -Rr '[scan("[\\p{L}\\p{N}]+")] | join(" ")') || return 1
  if [[ -z "${terms}" ]]; then
    echo "ERROR: Jira duplicate check has no searchable terms in the issue title" >&2
    return 1
  fi
  raw_file=$(mktemp)
  jql="project = $(_scribe_jql_quote "${SCRIBE_JIRA_PROJECT}") AND summary ~ $(_scribe_jql_quote "$(_scribe_jql_quote "${terms}")")"
  _scribe_jira_search_paginated "${jql}" '["summary"]' "${raw_file}" || rc=$?
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

# Create an issue in SCRIBE_JIRA_PROJECT. Body is read from stdin. Labels
# can be a JSON array or a comma-separated list; they are filtered against
# SCRIBE_JIRA_LABELS and validated before adding. Returns the issue browse URL.
#
# Delegates the actual POST to `fullsend issues create --tracker jira`,
# which handles Markdown-to-ADF conversion and the Jira REST call.
# Labels are added separately via the REST API because the CLI does not
# support a --labels flag.
forge_create_issue() {
  local _repo="$1" title="$2" labels="$3"
  local body response key url
  body=$(cat)
  response=$(printf '%s' "${body}" | fullsend issues create \
    --tracker jira \
    --project "${SCRIBE_JIRA_PROJECT}" \
    --type "${SCRIBE_JIRA_ISSUE_TYPE}" \
    --title "${title}" \
    --body - \
    --jira-url "${JIRA_BASE_URL}" \
    --jira-email "${JIRA_USER_EMAIL}") || {
    echo "ERROR: forge_create_issue: fullsend issues create failed in project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  }
  key=$(printf '%s' "${response}" | jq -r '.key // empty' 2>/dev/null)
  url=$(printf '%s' "${response}" | jq -r '.url // empty' 2>/dev/null)
  if [[ -z "${key}" ]] || [[ ! "${key}" =~ ^${SCRIBE_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: forge_create_issue: fullsend issues create returned no valid issue key" >&2
    return 1
  fi
  # tracker_validate_create sets SCRIBE_JIRA_LABELS_AVAILABLE=false when the
  # create screen has no Labels field; sending it would fail every create.
  # Note: SCRIBE_JIRA_LABELS_AVAILABLE is validated against createmeta (create
  # screen). The label PUT uses the edit screen, which usually agrees with the
  # create screen for the Labels field but is not separately validated. If the
  # edit screen differs, the PUT will fail and the issue is created without
  # labels — surfaced in the step summary and Slack output below.
  local label_failed=false
  if [[ "${SCRIBE_JIRA_LABELS_AVAILABLE:-true}" == "true" ]] && [[ -n "${labels}" ]]; then
    if ! _scribe_jira_add_labels "${key}" "${labels}"; then
      echo "WARNING: forge_create_issue: failed to add labels to ${key} (issue created without labels)" >&2
      label_failed=true
    fi
  fi
  if [[ -n "${url}" ]]; then
    echo "${url}"
  else
    echo "${JIRA_BASE_URL}/browse/${key}"
  fi
  # Return 2 to signal "created successfully but labels failed" so the
  # caller (post-scribe) can surface the failure in the run summary.
  [[ "${label_failed}" == "true" ]] && return 2
  return 0
}

forge_issue_url_base() {
  echo "${JIRA_BASE_URL}/browse"
}

# Normalize and filter labels for Jira against allowlist, format, and cap.
# Returns comma-separated string for display and logging.
forge_normalize_labels() {
  local labels="$1"
  printf '%s' "$(_scribe_jira_filter_labels "${labels}")" | jq -r 'join(",")'
}
