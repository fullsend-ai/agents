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
#   RETRO_JIRA_ISSUE_TYPE  — issue type name for created issues (default: "Task")
#   RETRO_JIRA_LABELS      — comma-separated allowlist of labels that retro may
#                            apply to Jira issues (default: "ready-for-triage").
#                            Labels are added by an issue update, which Jira
#                            checks against the issue edit screen, so an issue
#                            type whose edit screen has no Labels field gets no
#                            labels and a warning.
#   RETRO_JIRA_MAX_PAGES   — maximum pages fetched per paginated Jira read (default: 50)
#   RETRO_MODE             — "all" (default), "summary_only", or "issues_only"
#   RETRO_JIRA_CONTEXT_FILE — path the pre-script writes the originating Jira
#                            issue context to. Required for a Jira-originated
#                            run: harness/retro.yaml mounts exactly this path
#                            into the sandbox (host_files src), and a
#                            ${VAR}-expanded src is the only form fullsend
#                            accepts when the harness is loaded from a URL or
#                            used as a `base:`.
#
# REST routing mirrors fullsend's Jira Scoped client
# (internal/forge/jira/scoped.go), as jira-prioritize-ops.lib.sh does:
# tracker.jira.api_url in FULLSEND_DIR's config is the gateway base (default
# https://api.atlassian.com), the cloud ID is discovered from the site at
# tracker.jira.base_url (<site>/_edge/tenant_info), and every REST call goes
# to <api_url>/ex/jira/<cloudId>/rest/api/3/... . A JIRA_API_URL environment
# variable is not read: the gateway comes only from tracker.jira in the
# config, as it does for the `fullsend issues` CLI. Configuration is read
# from FULLSEND_DIR, the same directory the CLI reads.

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

# Credentials are expanded into curl and CLI arguments below. Turn xtrace
# off around those expansions so `bash -x` / `set -x` never writes the token
# to the trace, then restore the caller's setting.
_RETRO_JIRA_XTRACE=0
_retro_jira_xtrace_off() {
  _RETRO_JIRA_XTRACE=0
  if [[ $- == *x* ]]; then
    _RETRO_JIRA_XTRACE=1
    set +x
  fi
}
_retro_jira_xtrace_restore() {
  if [[ "${_RETRO_JIRA_XTRACE}" -eq 1 ]]; then
    set -x
  fi
}

_retro_jira_select_rc=0
_retro_jira_xtrace_off
jira_auth_select "${JIRA_TOKEN:-}" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET || _retro_jira_select_rc=$?
_retro_jira_xtrace_restore
if [[ "${_retro_jira_select_rc}" -ne 0 ]]; then
  exit 1
fi

if [[ "${RETRO_MODE}" != "summary_only" && "${JIRA_AUTH_MODE}" == "none" ]]; then
  echo "ERROR: JIRA_TOKEN must be set, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
  exit 1
fi
# Client-credentials access tokens are accepted by the Atlassian API
# gateway, which tracker.jira.api_url points at, so no separate gateway URL
# is required. The resolved endpoint is validated per call.

if [[ -n "${JIRA_BASE_URL:-}" ]]; then
  while [[ "${JIRA_BASE_URL}" == */ ]]; do
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"
  done
  if [[ ! "${JIRA_BASE_URL}" =~ ^https://[a-zA-Z0-9-]+\.atlassian\.net$ ]]; then
    echo "ERROR: JIRA_BASE_URL must be a Jira Cloud URL (https://<site>.atlassian.net)" >&2
    exit 1
  fi
fi

if [[ "${RETRO_MODE}" != "summary_only" ]]; then
  [[ -n "${FULLSEND_DIR:-}" ]] || {
    echo "ERROR: FULLSEND_DIR must be set when FULLSEND_TRACKER=jira" >&2
    exit 1
  }
fi

# Client-credentials tokens are not minted at source time: pre-retro mints
# and caches the REST root via _retro_jira_init only when JIRA_ORIGINATING=true
# to fetch the originating issue context, while forge-originated runs make no
# Jira calls in pre-retro. post-retro calls _retro_jira_init once in the main
# shell before the proposal loop. Minting there (rather than per call) keeps
# the token and REST root in the main process cache, avoiding token exchanges
# and tenant_info lookups inside subshell command substitutions.

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
# Used as an arithmetic bound, so anything outside a plain positive integer is
# refused: 0 yields a silent "truncated" duplicate search and a failing
# createmeta, and bash arithmetic would evaluate the contents of the value.
if [[ ! "${RETRO_JIRA_MAX_PAGES}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_MAX_PAGES must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_MAX_PAGES}"))" >&2
  exit 1
fi

# --- Configuration and REST routing ---

# Print the effective value of tracker.jira.<key> from the configuration in
# FULLSEND_DIR. The overlay (config.yaml) is composed over config.base.yaml
# with fullsend's whole-object tracker merge: an overlay that sets tracker
# replaces the base tracker as a whole object; a missing, null or bare
# tracker inherits the base. Prints nothing when no layer sets the key.
# Fails closed (non-zero) when a layer exists but cannot be read, so a yq
# parse error is never mistaken for "no config" and calls are not routed to
# the default gateway by accident.
_retro_jira_config_value() {
  local key="$1" cfg tracker value=""
  [[ -n "${FULLSEND_DIR:-}" ]] || return 0
  [[ -f "${FULLSEND_DIR}/config.yaml" || -f "${FULLSEND_DIR}/config.base.yaml" ]] || return 0
  if ! command -v yq &>/dev/null; then
    echo "ERROR: a Jira config file exists under FULLSEND_DIR but yq is not installed — cannot read tracker.jira.${key}" >&2
    return 1
  fi
  for cfg in "${FULLSEND_DIR}/config.yaml" "${FULLSEND_DIR}/config.base.yaml"; do
    [[ -f "${cfg}" ]] || continue
    tracker=$(yq -o=json '.tracker' "${cfg}" 2>/dev/null) || {
      echo "ERROR: failed to parse $(basename "${cfg}") — cannot read tracker.jira.${key}" >&2
      return 1
    }
    # An unset, null or bare tracker inherits the next layer.
    [[ "${tracker}" == "null" || -z "${tracker}" ]] && continue
    value=$(yq -r ".tracker.jira.${key} // \"\"" "${cfg}" 2>/dev/null) || {
      echo "ERROR: failed to parse tracker.jira.${key} from ${cfg}" >&2
      return 1
    }
    break
  done
  printf '%s' "${value}"
}

# Print the argument without trailing slashes.
_retro_jira_trim_url() {
  local url="$1"
  while [[ -n "${url}" && "${url}" == */ ]]; do
    url="${url%/}"
  done
  printf '%s' "${url}"
}

# Discover the site's cloud ID from <site>/_edge/tenant_info. The lookup is
# unauthenticated and does not follow redirects. The value must be a UUID
# before it is placed in a URL path.
_retro_jira_cloud_id() {
  local site="$1" resp id
  resp=$(curl -q --proto '=https' --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    "${site}/_edge/tenant_info") || {
    echo "ERROR: failed to discover the Jira cloud ID from ${site}/_edge/tenant_info" >&2
    return 1
  }
  id=$(printf '%s' "${resp}" | jq -r '.cloudId // empty' 2>/dev/null) || id=""
  if [[ ! "${id}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "ERROR: Jira cloud ID discovery from ${site} returned no valid cloudId" >&2
    return 1
  fi
  printf '%s' "${id}"
}

# Print the REST root for Jira Cloud REST API v3:
#   <tracker.jira.api_url>/ex/jira/<cloudId>/rest/api/3
# tracker.jira.api_url is the gateway base (default https://api.atlassian.com)
# and tracker.jira.base_url, when set, must name the JIRA_BASE_URL tenant so
# a config cannot route reads to a different site than the CLI writes to.
# Fails closed when the site or cloud ID cannot be resolved.
_retro_jira_rest_root() {
  local gateway site cfg_base cloud
  [[ -n "${JIRA_BASE_URL:-}" ]] || {
    echo "ERROR: JIRA_BASE_URL is not set" >&2
    return 1
  }
  gateway=$(_retro_jira_config_value api_url) || return 1
  gateway=$(_retro_jira_trim_url "${gateway:-https://api.atlassian.com}")
  if [[ ! "${gateway}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    echo "ERROR: tracker.jira.api_url is not a plain https URL: $(_gha_sanitize "${gateway}")" >&2
    return 1
  fi
  site="${JIRA_BASE_URL}"
  cfg_base=$(_retro_jira_config_value base_url) || return 1
  cfg_base=$(_retro_jira_trim_url "${cfg_base}")
  if [[ -n "${cfg_base}" && "${cfg_base}" != "${site}" ]]; then
    echo "ERROR: tracker.jira.base_url ('$(_gha_sanitize "${cfg_base}")') does not match JIRA_BASE_URL ('$(_gha_sanitize "${site}")') — refusing to route Jira calls to a different tenant" >&2
    return 1
  fi
  cloud=$(_retro_jira_cloud_id "${site}") || return 1
  printf '%s/ex/jira/%s/rest/api/3' "${gateway}" "${cloud}"
}

# Resolve the REST root once per run, in the calling shell. Every REST call
# below runs inside a command substitution, so a root resolved there is lost
# with the subshell and repeats 2-4 yq reads and an unauthenticated
# tenant_info request per call. Called from post-retro after configuration is
# parsed and before the proposal loop, as jira-prioritize-ops.lib.sh does
# with its cloud-ID cache.
_RETRO_JIRA_REST_ROOT=""
_retro_jira_init() {
  [[ "${RETRO_MODE}" == "summary_only" && "${JIRA_ORIGINATING:-false}" != "true" ]] && return 0
  # Mint in the calling shell so the token cache survives the subshells.
  jira_auth_mint || return 1
  local root=""
  # A resolution failure is not fatal here: _retro_jira_api re-resolves it and
  # reports the error for the proposal it affects, as it did before caching.
  if root=$(_retro_jira_rest_root); then
    _RETRO_JIRA_REST_ROOT="${root}"
  fi
  return 0
}

# --- Jira REST calls ---

_retro_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local rest_root="${_RETRO_JIRA_REST_ROOT:-}" rc=0
  if [[ -z "${rest_root}" ]]; then
    rest_root=$(_retro_jira_rest_root) || return 1
  fi
  _retro_jira_xtrace_off
  jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    "${rest_root}${endpoint}" \
    "$@" || rc=$?
  _retro_jira_xtrace_restore
  return "${rc}"
}

_retro_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file raw http_code body rest_root="${_RETRO_JIRA_REST_ROOT:-}" rc=0
  if [[ -z "${rest_root}" ]]; then
    rest_root=$(_retro_jira_rest_root) || return 1
  fi
  err_file=$(mktemp)
  _retro_jira_xtrace_off
  raw=$(jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${rest_root}${endpoint}" \
    "$@" 2>"${err_file}") || rc=$?
  _retro_jira_xtrace_restore
  if [[ "${rc}" -ne 0 ]]; then
    echo "Jira API error: curl failed — $(_gha_sanitize "$(cat "${err_file}")")" >&2
    rm -f "${err_file}"
    return 1
  fi
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

# --- Originating-issue context for the sandbox ---
#
# A Jira-originated retro runs in a sandbox with no route to Atlassian and no
# Jira credential, so pre-retro fetches the originating issue and its comments
# here, on the host, and the harness mounts the result into the sandbox
# (harness/retro.yaml host_files -> /sandbox/workspace/jira-origin.json, read
# by the agent as RETRO_JIRA_CONTEXT). Nothing in the sandbox talks to Jira.
#
# The path is the runner's, not a default: harness/retro.yaml declares it as
# the host_files src, so the path written here and the path mounted there must
# be the same value. pre-retro refuses a Jira-originated run without it.
RETRO_JIRA_CONTEXT_FILE="${RETRO_JIRA_CONTEXT_FILE:-}"
RETRO_JIRA_CONTEXT_MAX_BYTES="${RETRO_JIRA_CONTEXT_MAX_BYTES:-262144}"
RETRO_JIRA_CONTEXT_MAX_PAGES="${RETRO_JIRA_CONTEXT_MAX_PAGES:-10}"
RETRO_JIRA_CONTEXT_COMMENT_CHARS="${RETRO_JIRA_CONTEXT_COMMENT_CHARS:-4000}"
RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS="${RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS:-20000}"
# Used as arithmetic or jq bounds, so refuse anything but a positive integer,
# as RETRO_JIRA_MAX_PAGES does.
if [[ ! "${RETRO_JIRA_CONTEXT_MAX_BYTES}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_CONTEXT_MAX_BYTES must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_CONTEXT_MAX_BYTES}"))" >&2
  exit 1
fi
if [[ ! "${RETRO_JIRA_CONTEXT_MAX_PAGES}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_CONTEXT_MAX_PAGES must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_CONTEXT_MAX_PAGES}"))" >&2
  exit 1
fi
if [[ ! "${RETRO_JIRA_CONTEXT_COMMENT_CHARS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_CONTEXT_COMMENT_CHARS must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_CONTEXT_COMMENT_CHARS}"))" >&2
  exit 1
fi
if [[ ! "${RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS must be a positive integer (got: $(_gha_sanitize "${RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS}"))" >&2
  exit 1
fi

# Fetch every comment on an issue, oldest first, into a JSON array file.
# Pagination is bounded by RETRO_JIRA_CONTEXT_MAX_PAGES; a read stopped by that
# cap sets _RETRO_JIRA_COMMENTS_TRUNCATED, which the context builder copies into
# the file so the agent knows the list is incomplete. orderBy is explicit
# because the cap drops newest comments when the order is ascending, which is
# the order the byte-size trim and the docs assume.
_RETRO_JIRA_COMMENTS_TRUNCATED="false"
_retro_jira_fetch_comments() {
  local key="$1" out="$2" start=0 page resp count total
  _RETRO_JIRA_COMMENTS_TRUNCATED="false"
  printf '[]' > "${out}"
  for ((page = 1; page <= RETRO_JIRA_CONTEXT_MAX_PAGES; page++)); do
    resp=$(_retro_jira_api GET "/issue/${key}/comment?maxResults=100&startAt=${start}&orderBy=created") || return 1
    count=$(printf '%s' "${resp}" | jq -r '(.comments // []) | length') || return 1
    if ! printf '%s' "${resp}" | jq -c '(.comments // [])' \
      | jq -sc '.[0] + .[1]' "${out}" - > "${out}.tmp"; then
      echo "ERROR: Jira comment fetch returned a malformed response" >&2
      rm -f "${out}.tmp"
      return 1
    fi
    mv "${out}.tmp" "${out}"
    total=$(printf '%s' "${resp}" | jq -r '.total // empty')
    start=$((start + count))
    if [[ "${count}" -eq 0 ]] || [[ -n "${total}" && "${start}" -ge "${total}" ]]; then
      return 0
    fi
  done
  echo "WARNING: Jira comments stopped after ${RETRO_JIRA_CONTEXT_MAX_PAGES} pages; the sandbox context is truncated" >&2
  _RETRO_JIRA_COMMENTS_TRUNCATED="true"
  return 0
}

# Build the sandbox context file for the originating Jira issue. Prints the
# path written. Fails closed: the agent must not run a retrospective it
# cannot read.
_retro_jira_write_context() {
  local key="$1" file="${RETRO_JIRA_CONTEXT_FILE}"
  local raw_issue comments_file issue_file tmp
  if [[ ! "${key}" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]]; then
    echo "ERROR: cannot read a Jira issue key from '$(_gha_sanitize "${key}")'" >&2
    return 1
  fi
  if [[ -z "${file}" ]]; then
    echo "ERROR: RETRO_JIRA_CONTEXT_FILE is not set — harness/retro.yaml mounts that path into the sandbox as RETRO_JIRA_CONTEXT" >&2
    return 1
  fi
  if [[ -z "${JIRA_BASE_URL:-}" ]]; then
    echo "ERROR: JIRA_BASE_URL is not set" >&2
    return 1
  fi
  raw_issue=$(_retro_jira_api GET "/issue/${key}?fields=summary,description,status,issuetype,labels,created,updated,reporter,assignee,project,issuelinks,parent") || {
    echo "ERROR: failed to read Jira issue ${key}" >&2
    return 1
  }
  comments_file=$(mktemp)
  if ! _retro_jira_fetch_comments "${key}" "${comments_file}"; then
    rm -f "${comments_file}"
    echo "ERROR: failed to read comments on Jira issue ${key}" >&2
    return 1
  fi
  # The issue document goes in through a file, not argv: it holds the ADF
  # description, which is far larger than its text, and Linux caps a single
  # argument at 128 KiB (MAX_ARG_STRLEN), so --argjson fails with E2BIG on a
  # big issue. macOS has no such limit, so a local run would not show it.
  issue_file=$(mktemp)
  if ! printf '%s' "${raw_issue}" > "${issue_file}"; then
    rm -f "${comments_file}" "${issue_file}"
    echo "ERROR: failed to stage the Jira issue response" >&2
    return 1
  fi
  tmp=$(mktemp)
  if ! jq -n \
    --arg key "${key}" \
    --arg url "${JIRA_BASE_URL}/browse/${key}" \
    --slurpfile issue "${issue_file}" \
    --slurpfile comments "${comments_file}" \
    --argjson comments_truncated "${_RETRO_JIRA_COMMENTS_TRUNCATED}" \
    --argjson comment_chars "${RETRO_JIRA_CONTEXT_COMMENT_CHARS}" \
    --argjson description_chars "${RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS}" \
    --arg generated_by "retro pre-script (host-side fetch; the sandbox has no Jira access)" '
    # Jira stores rich text as ADF. Keep unknown node types as their text
    # children so a schema addition degrades instead of disappearing.
    def adf:
      if type == "string" then .
      elif type == "array" then map(adf) | join("")
      elif type == "object" then
        (if .type == "text" then (.text // "")
         elif .type == "hardBreak" then "\n"
         elif .type == "paragraph" then ((.content // [] | adf) + "\n")
         elif .type == "heading" then
           (("#" * ((.attrs.level // 1) | tonumber)) + " " + ((.content // [] | adf)) + "\n")
         elif .type == "codeBlock" then ("```\n" + ((.content // [] | adf)) + "```\n")
         elif .type == "listItem" then ("- " + ((.content // [] | adf)))
         elif .type == "mention" then ("@" + (.attrs.text // .attrs.displayName // "user"))
         elif .type == "inlineCard" then ((.attrs.url // "") + "\n")
         elif .type == "rule" then "---\n"
         else (.content // [] | adf) end)
      else "" end;
    def text_or_null:
      if . == null then "" else (adf | gsub("\\n{3,}"; "\n\n") | ltrimstr("\n") | rtrimstr("\n")) end;
    def clip(n): if length > n then .[0:n] + "\n…(truncated)" else . end;
    ($issue[0].fields // {}) as $f |
    {
      source: "jira",
      generated_by: $generated_by,
      issue: {
        key: $key,
        url: $url,
        summary: ($f.summary // ""),
        project: ($f.project.key // ""),
        issue_type: ($f.issuetype.name // ""),
        status: ($f.status.name // ""),
        labels: (($f.labels // []) | map(select(type == "string"))),
        created: ($f.created // ""),
        updated: ($f.updated // ""),
        reporter: ($f.reporter.displayName // ""),
        assignee: ($f.assignee.displayName // ""),
        parent: ($f.parent.key // ""),
        links: (($f.issuelinks // [])
          | map({type: (.type.name // ""), key: (((.outwardIssue // .inwardIssue) // {}).key // "")})
          | map(select(.key != ""))),
        description: (($f.description | text_or_null) | clip($description_chars)),
        description_truncated: ((($f.description | text_or_null) | length) > $description_chars)
      },
      comments: (($comments[0] // [])
        | map({
            id: (.id // ""),
            author: (.author.displayName // ""),
            created: (.created // ""),
            body: ((.body | text_or_null) | clip($comment_chars))
          })),
      comments_truncated: $comments_truncated
    }' > "${tmp}"; then
    rm -f "${comments_file}" "${issue_file}" "${tmp}"
    echo "ERROR: failed to assemble the Jira context file" >&2
    return 1
  fi
  rm -f "${comments_file}" "${issue_file}"
  # Keep the file under the size cap by dropping the oldest comments first:
  # the newest discussion is what a retrospective needs most.
  while [[ "$(wc -c < "${tmp}" | tr -d '[:space:]')" -gt "${RETRO_JIRA_CONTEXT_MAX_BYTES}" ]] \
    && [[ "$(jq '.comments | length' "${tmp}")" -gt 0 ]]; do
    if ! jq '(.comments | length) as $n
      | .comments = .comments[(if $n > 4 then ($n / 4 | floor) else 1 end):]
      | .comments_truncated = true' "${tmp}" > "${tmp}.cut"; then
      rm -f "${tmp}" "${tmp}.cut"
      echo "ERROR: failed to trim the Jira context file" >&2
      return 1
    fi
    mv "${tmp}.cut" "${tmp}"
  done
  chmod 600 "${tmp}"
  mkdir -p "$(dirname "${file}")"
  mv "${tmp}" "${file}"
  printf '%s' "${file}"
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

# Jira validates a label update against the issue's edit screen, not the create
# screen createmeta reports: an issue type can offer Labels at creation and
# still refuse the update, or omit it at creation and accept the update. Label
# support is therefore decided from `GET /issue/{key}/editmeta`, probed once
# per run and cached, because tracker_apply_labels runs in the calling shell.
_RETRO_JIRA_LABELS_EDITABLE="unknown"

# Fail (non-zero) when the issue's edit screen has no Labels field, so no
# update is sent that Jira would reject.
_retro_jira_labels_editable() {
  local key="$1" editmeta
  case "${_RETRO_JIRA_LABELS_EDITABLE}" in
    yes) return 0 ;;
    no) return 1 ;;
  esac
  if ! editmeta=$(_retro_jira_api GET "/issue/${key}/editmeta"); then
    # Unknown rather than blocked: the update below reports its own failure.
    echo "WARNING: cannot read Jira edit metadata for ${key}; attempting the label update anyway" >&2
    return 0
  fi
  if printf '%s' "${editmeta}" | jq -e '((.fields // {}) | type == "object") and ((.fields // {}) | has("labels"))' >/dev/null 2>&1; then
    _RETRO_JIRA_LABELS_EDITABLE="yes"
    return 0
  fi
  _RETRO_JIRA_LABELS_EDITABLE="no"
  echo "WARNING: issue type '$(_gha_sanitize "${RETRO_JIRA_ISSUE_TYPE}")' in Jira project ${RETRO_JIRA_PROJECT} has no Labels field on its edit screen; labels will be omitted" >&2
  return 1
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
  if ! _retro_jira_labels_editable "${key}"; then
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
  # The create call below passes both options, so the installed CLI must
  # support both. Cobra prints "Usage:" and the command path on separate
  # lines, so match the command path itself rather than a contiguous
  # "Usage: <cmd>" string. Any help output that does not establish the
  # create command and both options fails preflight here, instead of every
  # proposal failing later with an unknown-flag error.
  if ! help_text=$(fullsend issues create --help 2>&1) \
    || [[ "${help_text}" != *"fullsend issues create"* ]] \
    || [[ "${help_text}" != *"--fullsend-dir"* ]] \
    || [[ "${help_text}" != *"--tracker"* ]]; then
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
  # Labels are not checked here: they are written by an issue update, which
  # Jira validates against the edit screen, not this create screen. See
  # tracker_apply_labels.
}

tracker_find_existing_issue() {
  local title="$1" raw_file jql terms match rc=0
  # Search terms are whole whitespace-separated words of letters and digits;
  # a dotted or hyphenated token such as `post-retro.sh` is not split, since
  # Jira may index it as one token and a fragment would miss the exact
  # summary. Stop words are dropped so they cannot exclude an exact summary.
  # With no usable terms, search the project and compare summaries
  # client-side.
  terms=$(printf '%s' "${title}" | jq -Rs '[splits("[[:space:]]+") | select(test("^[\\p{L}\\p{N}]+$")) | ascii_downcase] | unique | map(select(length > 2 and (. as $word | (["a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is", "it", "no", "not", "of", "on", "or", "such", "that", "the", "their", "then", "there", "these", "they", "this", "to", "was", "will", "with"] | index($word) | not)))) | sort_by(-length) | .[0:3]') || return 1
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

# Titles filed, or matched as already filed, earlier in this run, with their
# issue URLs. The duplicate search below is the only rerun protection and it
# reads /search/jql, whose index lags behind writes: a second proposal with the
# same summary, or a retry moments after a create, would not see the issue the
# earlier iteration just filed. Checking this set first closes that gap. It
# lives in the calling shell (post-retro's proposal loop), which is also where
# the create runs.
_RETRO_JIRA_RUN_TITLES='[]'
_retro_jira_title_seen() {
  jq -e --arg t "$1" 'map(select(.title == $t)) | length > 0' <<<"${_RETRO_JIRA_RUN_TITLES}" >/dev/null 2>&1
}
_retro_jira_title_url() {
  jq -r --arg t "$1" '[.[] | select(.title == $t)][0].url // empty' <<<"${_RETRO_JIRA_RUN_TITLES}" 2>/dev/null
}
_retro_jira_record_title() {
  _RETRO_JIRA_RUN_TITLES=$(jq -c --arg t "$1" --arg u "${2:-}" '. + [{title: $t, url: $u}]' <<<"${_RETRO_JIRA_RUN_TITLES}")
}

forge_create_issue() {
  # The fourth argument is the label list, which post-retro applies with
  # tracker_apply_labels after the create (labels are an edit-screen field).
  # shellcheck disable=SC2034
  local _repo="$1" title="$2" body="$3" labels="${4:-ready-for-triage}"
  if [[ -z "${body}" || "${body}" == "-" ]]; then
    body=$(cat)
  fi
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: forge_create_issue: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  local response key url rc=0
  _retro_jira_xtrace_off
  response=$(printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues create \
    --tracker jira \
    --fullsend-dir "${FULLSEND_DIR}" \
    --project "${RETRO_JIRA_PROJECT}" \
    --type "${RETRO_JIRA_ISSUE_TYPE}" \
    --title "${title}" \
    --body -) || rc=$?
  _retro_jira_xtrace_restore
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: forge_create_issue: fullsend issues create failed in project ${RETRO_JIRA_PROJECT}" >&2
    return 1
  fi
  key=$(printf '%s' "${response}" | jq -r '.key // empty' 2>/dev/null)
  url=$(printf '%s' "${response}" | jq -r '.url // empty' 2>/dev/null)
  if [[ -z "${key}" ]] || [[ ! "${key}" =~ ^${RETRO_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: forge_create_issue: fullsend issues create returned no valid issue key" >&2
    return 1
  fi
  if [[ -n "${url}" ]]; then
    echo "${url}"
  else
    echo "${JIRA_BASE_URL}/browse/${key}"
  fi
}

# Apply RETRO_JIRA_LABELS to a created issue. post-retro calls this in its own
# shell, after a successful create, so the edit-screen probe in
# _retro_jira_labels_editable is cached for the proposals that follow:
# forge_create_issue runs in a command substitution, whose variable state does
# not survive.
#
# Usage: tracker_apply_labels <issue-url> <labels>
tracker_apply_labels() {
  local url="$1" labels="$2" key
  key="${url##*/}"
  if [[ ! "${key}" =~ ^${RETRO_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: tracker_apply_labels: cannot read a ${RETRO_JIRA_PROJECT} issue key from '$(_gha_sanitize "${url}")'" >&2
    return 1
  fi
  _retro_jira_add_labels "${key}" "${labels}"
}

forge_create_label() {
  # Jira labels are ad-hoc strings and do not require pre-creation.
  return 0
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

# `fullsend issues post-comment` updates a marked comment in place. Older
# CLIs keep the replaced text as a collapsed "Previous run" block unless
# --keep-history=false is passed, which would stack a copy of the previous
# summary on every rerun. fullsend-ai/fullsend#9399, still open, proposes
# deprecating the flag and posting every result as a new comment; once that
# merges, passing the flag prints a warning and has no effect, and each rerun
# adds another summary comment instead of replacing the previous one. The
# flag is therefore passed only when the CLI's flag table lists it without
# "deprecated", which covers a released CLI either way.
# Sets _RETRO_JIRA_KEEP_HISTORY_ARGS in the caller's shell.
_RETRO_JIRA_KEEP_HISTORY_ARGS=()
_retro_jira_keep_history_args() {
  _RETRO_JIRA_KEEP_HISTORY_ARGS=()
  local help_text line has_flag=0 deprecated=0
  if ! help_text=$(fullsend issues post-comment --help 2>&1); then
    # A broken CLI fails the post itself, with its own error.
    return 0
  fi
  help_text=$(printf '%s\n' "${help_text}" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r line; do
    [[ "${line}" =~ ^[[:space:]]+--keep-history([=[:space:]]|$) ]] || continue
    has_flag=1
    if [[ "${line}" == *deprecated* ]]; then
      deprecated=1
    fi
  done <<< "${help_text}"
  if [[ "${has_flag}" -eq 1 && "${deprecated}" -eq 0 ]]; then
    _RETRO_JIRA_KEEP_HISTORY_ARGS=(--keep-history=false)
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
  local rc=0
  _retro_jira_keep_history_args
  _retro_jira_xtrace_off
  printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues post-comment --tracker jira --fullsend-dir "${FULLSEND_DIR}" \
    --project "${repo}" --number "${num}" \
    --marker "<!-- fullsend:retro-agent -->" \
    ${_RETRO_JIRA_KEEP_HISTORY_ARGS[@]+"${_RETRO_JIRA_KEEP_HISTORY_ARGS[@]}"} \
    --result - 2>&1 || rc=$?
  _retro_jira_xtrace_restore
  return "${rc}"
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
  # issues_only posts no forge comment, so a forge token is not required for
  # a Jira-backed run that only files issues.
  if [[ "${RETRO_MODE}" == "issues_only" ]]; then
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
  # The test below and the mask itself both expand the token, so keep them
  # out of any xtrace.
  _retro_jira_xtrace_off
  if [[ -n "${GITHUB_ACTIONS:-}" && -n "${JIRA_TOKEN:-}" ]]; then
    _gha_mask "${JIRA_TOKEN}"
  fi
  _retro_jira_xtrace_restore
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
