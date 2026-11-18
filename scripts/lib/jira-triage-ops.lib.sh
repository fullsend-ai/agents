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
#   JIRA_TOKEN      — Jira API token (the triage harness maps
#                     FULLSEND_JIRA_TOKEN to it). Or, instead of it:
#   FULLSEND_JIRA_CLIENT_ID, FULLSEND_JIRA_CLIENT_SECRET
#                   — service-account OAuth 2.0 client credentials. REST
#                     calls then use an access token minted on the runner
#                     and need JIRA_API_URL. Setting both modes fails.
#   JIRA_USER_EMAIL — (optional) bot-user email (the triage harness maps
#                     FULLSEND_JIRA_EMAIL to it). When set, requests use
#                     Basic auth with email and token; when unset or
#                     empty, Bearer auth with a service-account token.
#                     See lib/jira-auth.lib.sh.
#   FULLSEND_DIR    — .fullsend directory whose config.yaml holds
#                     tracker.jira, for the `fullsend issues` shell-outs
#   JIRA_API_URL    — (optional) where REST calls go, e.g. the Atlassian
#                     API gateway https://api.atlassian.com/ex/jira/<cloudId>
#                     that `fullsend run` resolves and exports. Falls back
#                     to JIRA_BASE_URL when unset (older fullsend releases),
#                     except with client credentials, which require it.
#                     Browse links always use JIRA_BASE_URL.
#
# The `fullsend issues` CLI reads its credentials from FULLSEND_JIRA_TOKEN
# and, for a bot user, FULLSEND_JIRA_EMAIL, and its Jira site and API
# gateway from tracker.jira in --fullsend-dir. jira_auth_fullsend passes
# the same token and email to it, or the client credentials, so one set of
# credentials covers both the raw REST calls in this file and the
# `fullsend` shell-outs below.
#
# Optional env vars:
#   JIRA_DUPLICATE_TRANSITION   — transition name for the "duplicate" action
#   JIRA_NOT_PLANNED_TRANSITION — transition name for the "not planned" action
#   JIRA_SPLIT_TRANSITION       — transition name for the "split" and
#                                 "completed" actions (both close with
#                                 GitHub reason "completed")
#   JIRA_CREATE_ISSUE_TYPE      — issue type name for cross-project issue
#                                 creation (default: "Task")

[[ -n "${JIRA_TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
JIRA_TRIAGE_OPS_SH_LOADED=1

# Validate credentials at source time — fails once, early, on unredirected
# stderr, before any call site can swallow the diagnostic with 2>/dev/null.
# Matches the idiom pre-triage.src.sh / post-triage.src.sh already use for
# ISSUE_URL and FULLSEND_TRACKER.
# JIRA_USER_EMAIL is optional: without it, requests use Bearer auth.
# shellcheck source=jira-auth.lib.sh
source "${SCRIPT_DIR}/lib/jira-auth.lib.sh"
jira_auth_select "${JIRA_TOKEN:-}" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET || exit 1
if [[ "${JIRA_AUTH_MODE}" == "none" ]]; then
  echo "ERROR: JIRA_TOKEN must be set, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
  exit 1
fi
# JIRA_API_URL is optional, but the credentials are sent to it, so refuse
# anything that is not https.
if [[ -n "${JIRA_API_URL:-}" && "${JIRA_API_URL}" != https://* ]]; then
  echo "ERROR: JIRA_API_URL must start with https://" >&2
  exit 1
fi
jira_auth_require_api_url || exit 1
# Client credentials: mint the access token here, in the script's own
# shell, so later REST calls reuse it. A failure is reported here and each
# REST call then fails on its own, keeping the caller's fail-open or
# fail-closed handling.
jira_auth_mint || true

# JIRA_BASE_URL is derived at runtime by tracker_parse_issue_url, so it
# cannot be validated at source time — keep a per-call guard for it.
_jira_require_vars() {
  if [[ -z "${JIRA_BASE_URL:-}" ]]; then echo "ERROR: JIRA_BASE_URL is not set" >&2; return 1; fi
}

# Print the base URL for REST calls: JIRA_API_URL when set, else
# JIRA_BASE_URL, with trailing slash(es) stripped.
_jira_api_base() {
  local base="${JIRA_API_URL:-${JIRA_BASE_URL}}"
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

  jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --request "${method}" \
    "${api_base}/rest/api/3${endpoint}" \
    "$@"
}

_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift

  _jira_require_vars || return 1
  local api_base
  api_base=$(_jira_api_base) || return 1

  local err_file
  err_file=$(mktemp)
  local raw
  raw=$(jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${api_base}/rest/api/3${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "Jira API error: curl failed — $(grep -v '^::add-mask::' "${err_file}")" >&2
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
  # Strip trailing slash(es) from JIRA_BASE_URL so that a copy-pasted
  # "https://acme.atlassian.net/" matches the parsed "https://acme.atlassian.net".
  # Loop rather than a single ${VAR%/} so that "…net//" normalises too.
  while [[ -n "${JIRA_BASE_URL:-}" && "${JIRA_BASE_URL}" == */ ]]; do
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"
  done
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
  # Jira treats removing an absent label as a no-op, so an error here is a
  # real write failure. Fail the step instead of reporting success.
  if ! _jira_api PUT "/issue/${ISSUE_NUMBER}" \
    --data "$(jq -cn --arg l "${label}" '{update:{labels:[{remove:$l}]}}')" > /dev/null; then
    echo "ERROR: failed to remove label '${label}' from issue ${ISSUE_NUMBER} via PUT /issue/${ISSUE_NUMBER}" >&2
    return 1
  fi
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

  # An unparseable body must not read as "no labels remaining" — parse it up
  # front so a bad shape fails loudly, matching the GitHub/GitLab sentinel.
  local current_labels
  current_labels=$(echo "${raw_labels}" | jq -r '[.fields.labels[]] | join("\n")' 2>/dev/null) \
    || current_labels="VERIFY_FAILED"
  if [[ "${current_labels}" == "VERIFY_FAILED" ]]; then
    echo "ERROR: cannot verify label state — unexpected response shape" >&2
    return 1
  fi

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
  done <<< "${current_labels}"

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

# Alias used by labels.lib.sh (forge_ensure_label delegates to forge_create_label).
forge_create_label() {
  tracker_create_label "$@"
}

# --- Components ---

# Set components on a Jira issue. Accepts a JSON array of component objects
# (e.g., [{"name":"backend"},{"name":"frontend"}]) and replaces the issue's
# component list with that set.
tracker_set_components() {
  local components_json="$1"
  if ! _jira_api PUT "/issue/${ISSUE_NUMBER}" \
    --data "$(jq -cn --argjson c "${components_json}" '{fields:{components:$c}}')" > /dev/null; then
    echo "ERROR: failed to set components on issue ${ISSUE_NUMBER} via PUT /issue/${ISSUE_NUMBER}" >&2
    return 1
  fi
}

# Get current components on a Jira issue. Returns a JSON array of component
# name strings (e.g., ["backend","frontend"]).
tracker_get_components() {
  local response
  response=$(_jira_api GET "/issue/${ISSUE_NUMBER}?fields=components" 2>/dev/null) || {
    echo "ERROR: failed to get components for issue ${ISSUE_NUMBER}" >&2
    return 1
  }
  echo "${response}" | jq -r '[(.fields.components // [])[].name]'
}

# --- Comments ---

tracker_post_comment() {
  local body="$1"
  _jira_require_vars || return 1
  # `fullsend issues post-comment` always does marker-based find-and-update;
  # there is no "always create new" mode. Each triage run gets a new comment,
  # matching tracker_post_comment's always-new contract on GitHub/GitLab.
  # The marker is scoped to the CI run (GITHUB_RUN_ID survives a workflow
  # re-run, CI_PIPELINE_ID a GitLab job retry), so a retried run edits its
  # own earlier comment instead of posting a duplicate.
  local marker stamp
  local run_id="${GITHUB_RUN_ID:-${CI_PIPELINE_ID:-}}"
  if [[ "${run_id}" =~ ^[0-9]+$ ]]; then
    marker="<!-- fullsend:triage-run-${run_id} -->"
  else
    # No CI run ID: a marker unique to this invocation guarantees no prior
    # comment matches it.
    stamp=$(date +%s%N)
    # BSD date without %N support leaves the literal "N" in place, which would
    # make the marker identical for every invocation within the same second and
    # break the always-create-new contract. Fall back to a random suffix.
    if [[ "${stamp}" == *N* ]]; then
      stamp="$(date +%s)${RANDOM}${RANDOM}"
    fi
    marker="<!-- fullsend:triage-${stamp} -->"
  fi
  _jira_post_comment "${body}" "${marker}"
}

tracker_post_sticky_comment() {
  local body="$1"
  local marker="$2"
  _jira_require_vars || return 1
  _jira_post_comment "${body}" "${marker}"
}

# Post or update the comment carrying <marker> through the fullsend CLI,
# which takes the Jira site and API gateway from tracker.jira in
# FULLSEND_DIR's config.yaml and the credentials from its environment.
_jira_post_comment() {
  local body="$1"
  local marker="$2"
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${REPO}" --number "${JIRA_ISSUE_NUM}" \
    --marker "${marker}" --result -
}

# _jira_own_marked_comments MARKER — print, as a JSON array, every comment
# on the issue (all pages) that the posting account (GET /myself) wrote
# with the comment property fullsend.sticky-marker = {"marker": MARKER},
# each with a "_created" and "_updated" sort key ([UTC seconds,
# nanoseconds, numeric id]). `fullsend issues post-comment` sets that
# property on the comment it posts: in fullsend v0.56.1-rc.1 (pinned in
# go.mod) and v0.56.1 it edits that comment in place, and on
# fullsend-ai/fullsend#9399 (head 5150c261) every run creates a new comment
# with it (internal/tracker/jira_client.go, CreateCommentWithMarker;
# internal/cli/issues.go, postJiraStickyComment). Jira writes times as
# "2026-11-17T10:00:00.000+0100"; RFC 3339 "Z" and "+01:00" forms, with or
# without fractional seconds, are accepted too (fullsend's
# jiraTimestampFormats). A time that does not parse is an error.
_jira_own_marked_comments() {
  local marker="$1"
  local self
  self=$(_jira_api_with_status GET "/myself" | jq -r '.accountId // empty') || return 1
  if [[ -z "${self}" ]]; then
    echo "ERROR: GET /myself returned no accountId" >&2
    return 1
  fi
  local comments="[]" page count total start_at=0
  while :; do
    page=$(_jira_api_with_status GET "/issue/${ISSUE_NUMBER}/comment?expand=properties&orderBy=-created&maxResults=100&startAt=${start_at}") || return 1
    comments=$(jq -c --argjson acc "${comments}" '$acc + (.comments // [])' <<<"${page}") || return 1
    count=$(jq -r '.comments // [] | length' <<<"${page}") || return 1
    total=$(jq -r '.total // 0' <<<"${page}") || return 1
    start_at=$((start_at + count))
    if [[ ${count} -eq 0 || ${start_at} -ge ${total} ]]; then
      break
    fi
  done
  jq -c --arg self "${self}" --arg marker "${marker}" '
    def utc_key:
      . as $t
      | (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<f>[0-9]{1,9}))?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")
         // error("unparsable Jira timestamp: \($t)"))
      | [ ((.d + "Z") | fromdateiso8601)
          - (if .z == "Z" then 0
             else (if .s == "+" then 1 else -1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60) end),
          (((.f // "") + "000000000")[0:9] | tonumber) ];
    [ .[] | select(.author.accountId == $self)
      | select(any(.properties[]?; .key == "fullsend.sticky-marker" and (.value.marker? == $marker)))
      | (.id | tostring | tonumber? // 0) as $n
      | . + {_created: (((.created // "") | utc_key) + [$n]),
             _updated: (((.updated // .created // "") | utc_key) + [$n])} ]
  ' <<<"${comments}"
}

# The comment whose state tracker_clear_triage_state removed, and that
# state, so tracker_store_triage_state can put it back when the post turned
# out to create a new comment instead of editing that one.
_TRIAGE_CLEARED_ID=""
_TRIAGE_CLEARED_STATE=""

# tracker_clear_triage_state MARKER — before a run posts, delete the
# fullsend.triage-state property from the one comment an edit in place
# would rewrite: fullsend v0.56.1-rc.1 lists comments oldest first
# (internal/forge/jira/client.go, ListComments, orderBy=created) and edits
# the first own one with MARKER (FindCommentByMarkerProperty), so the
# oldest. Without this, a run cancelled before tracker_store_triage_state,
# or one with no state, would leave the previous state on the new text.
# Other comments keep their states: after fullsend-ai/fullsend#9399 the
# post creates a new comment and every earlier state stays valid.
tracker_clear_triage_state() {
  local marker="$1"
  _jira_require_vars || return 1
  local comments target
  comments=$(_jira_own_marked_comments "${marker}") || {
    echo "ERROR: cannot clear the previous triage state" >&2
    return 1
  }
  target=$(jq -c 'min_by(._created) // empty' <<<"${comments}") || return 1
  [[ -n "${target}" ]] || return 0
  _TRIAGE_CLEARED_STATE=$(jq -c 'first(.properties[]? | select(.key == "fullsend.triage-state") | .value) // empty' <<<"${target}") || return 1
  [[ -n "${_TRIAGE_CLEARED_STATE}" ]] || return 0
  _TRIAGE_CLEARED_ID=$(jq -r '.id' <<<"${target}") || return 1
  _jira_api_with_status DELETE "/comment/${_TRIAGE_CLEARED_ID}/properties/fullsend.triage-state" > /dev/null || return 1
  echo "Cleared the previous triage state from comment ${_TRIAGE_CLEARED_ID}"
}

# tracker_store_triage_state STATE_JSON MARKER — after the post, store the
# triage state (when there is one) on the comment just posted with MARKER,
# as its entity property fullsend.triage-state (ADF has no hidden text).
# `fullsend issues post-comment` prints no comment id, so the comment is
# the own one with MARKER updated last; a tie goes to the highest comment
# id. If that is not the comment tracker_clear_triage_state cleared, the
# post created a new comment, and the cleared state goes back where it was.
# A time that does not parse, or no matching comment, fails the run, like
# every other Jira write.
tracker_store_triage_state() {
  local state="$1"
  local marker="$2"
  _jira_require_vars || return 1
  # No state to store and nothing cleared to restore.
  if [[ -z "${state}" && -z "${_TRIAGE_CLEARED_ID}" ]]; then
    return 0
  fi
  local comments comment_id
  comments=$(_jira_own_marked_comments "${marker}") || {
    echo "ERROR: cannot store the triage state: the comment listing or a timestamp in it could not be read" >&2
    return 1
  }
  comment_id=$(jq -r 'max_by(._updated) | .id // empty' <<<"${comments}") || return 1
  if [[ -z "${comment_id}" ]]; then
    echo "ERROR: cannot store the triage state: no comment by this account carries ${marker}" >&2
    return 1
  fi
  if [[ -n "${_TRIAGE_CLEARED_ID}" && "${_TRIAGE_CLEARED_ID}" != "${comment_id}" ]]; then
    _jira_api_with_status PUT "/comment/${_TRIAGE_CLEARED_ID}/properties/fullsend.triage-state" \
      --data "${_TRIAGE_CLEARED_STATE}" > /dev/null || return 1
    echo "Restored the triage state on comment ${_TRIAGE_CLEARED_ID} (this run posted a new comment)"
  fi
  [[ -n "${state}" ]] || return 0
  _jira_api_with_status PUT "/comment/${comment_id}/properties/fullsend.triage-state" \
    --data "${state}" > /dev/null || return 1
  echo "Stored the triage state on comment ${comment_id}"
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

_text_to_adf() {
  # Convert plain text to Atlassian Document Format (ADF) JSON.
  # Splits on blank lines into separate paragraphs; within a paragraph,
  # single newlines become hardBreak nodes.
  local text="$1"
  jq -cn --arg text "${text}" '
    # Split into paragraphs on blank lines (two or more consecutive newlines).
    ($text | split("\n\n")) as $paragraphs |
    {
      type: "doc",
      version: 1,
      content: [
        $paragraphs[] |
        select(length > 0) |
        # Split each paragraph on single newlines and interleave hardBreak nodes.
        (split("\n") | map(select(length > 0))) as $lines |
        select(($lines | length) > 0) |
        {
          type: "paragraph",
          content: (
            reduce $lines[] as $line (
              {idx: 0, nodes: []};
              if .idx > 0 then
                .nodes += [{type: "hardBreak"}, {type: "text", text: $line}]
              else
                .nodes += [{type: "text", text: $line}]
              end | .idx += 1
            ) | .nodes
          )
        }
      ]
    }
  '
}

tracker_create_issue() {
  local target_repo="$1"
  local title="$2"
  local body="$3"
  local issue_type="${JIRA_CREATE_ISSUE_TYPE:-Task}"
  # Jira Cloud REST v3 requires the description as Atlassian Document
  # Format, not plain text/markdown. Multi-line bodies are split into
  # ADF paragraphs (on blank lines) with hardBreak nodes for single
  # newlines within a paragraph.
  local description_adf
  description_adf=$(_text_to_adf "${body}")
  local response
  response=$(_jira_api_with_status POST "/issue" \
    --data "$(jq -cn --arg proj "${target_repo}" --arg title "${title}" \
      --arg itype "${issue_type}" --argjson desc "${description_adf}" \
      '{fields:{project:{key:$proj},summary:$title,description:$desc,issuetype:{name:$itype}}}')") || {
    echo "Jira API error: failed to create issue in ${target_repo}" >&2
    return 1
  }
  local key
  key=$(echo "${response}" | jq -r '.key // empty' 2>/dev/null)
  if [[ -z "${key}" ]]; then
    echo "ERROR: Jira create-issue response for ${target_repo} contained no issue key" >&2
    return 1
  fi
  echo "${JIRA_BASE_URL}/browse/${key}"
}

# Apply ready-for-triage to a newly created issue so Jira dispatch can
# pick it up. Failures are non-fatal for the caller.
#
# target_project must be the same already-allowlisted project key (checked
# via is_target_allowed) that created_url's issue was created in. Unlike
# GitHub/GitLab, the issue key used to address the label PUT (not just a
# REPO global) has to be derived from created_url, so this validates the
# URL against the same anchored pattern tracker_validate_issue_url uses and
# then rebuilds the issue key from target_project plus only the numeric
# suffix of created_url — rather than trusting the project name parsed out
# of created_url — before mutating.
tracker_dispatch_triage() {
  local created_url="$1"
  local target_project="$2"
  local saved_number="${ISSUE_NUMBER}"
  if [[ ! "${created_url}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
    echo "ERROR: created_url does not match expected Jira pattern: $(_gha_sanitize "${created_url}")" >&2
    return 1
  fi
  local parsed_key="${created_url##*/browse/}"
  if [[ -n "${target_project}" ]]; then
    # Rebuild the issue key from the already-allowlisted target project
    # plus only the numeric suffix from created_url, rather than trusting
    # the project name parsed out of created_url.
    ISSUE_NUMBER="${target_project}-${parsed_key##*-}"
  else
    ISSUE_NUMBER="${parsed_key}"
  fi
  local rc=0
  if ! tracker_add_label "ready-for-triage"; then
    echo "::warning::Failed to add ready-for-triage label to $(_gha_sanitize "${created_url}")" >&2
    rc=1
  fi
  ISSUE_NUMBER="${saved_number}"
  return "${rc}"
}
