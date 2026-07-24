#!/usr/bin/env bash
# comment-helpers.sh — Shared helpers for posting sticky comments to GitHub/Jira.
#
# Sticky comments: each agent (explore, refine, critique) maintains a single
# comment on the issue. On re-run, the existing comment is edited rather than
# creating a new one.
#
# GitHub: delegates to `fullsend post-comment` CLI which handles sticky
# lifecycle (find by marker → collapse old content into <details> → update).
# This matches the behavior of triage/review agents upstream.
#
# Jira: custom implementation using ADF with collapsed expand-node history
# (upstream fullsend doesn't support Jira yet).
#
# Usage:
#   source "${SCRIPT_DIR}/comment-helpers.sh"
#   init_comment_helpers "explore" "$USE_GITHUB"
#   sticky_comment "$body"
#
# Required env vars (set before sourcing):
#   ISSUE_KEY, ISSUE_SOURCE, JIRA_HOST, JIRA_EMAIL, JIRA_API_TOKEN
#   GITHUB_ISSUE_NUMBER, REPO_FULL_NAME, GH_TOKEN (for GitHub flow)

_CH_AGENT=""
_CH_USE_GITHUB=false
_CH_MARKER=""
_CH_GH_MARKER=""
# Total "Previous · …" expand nodes to retain (including the new snapshot).
_CH_MAX_HISTORY=3

validate_jira_host() {
  if [[ -z "${JIRA_HOST:-}" ]]; then
    echo "ERROR: JIRA_HOST not set"
    exit 1
  fi
  if [[ ! "${JIRA_HOST}" =~ ^[a-zA-Z0-9.-]+\.atlassian\.net$ ]]; then
    echo "ERROR: JIRA_HOST must be a *.atlassian.net hostname, got: ${JIRA_HOST}"
    exit 1
  fi
}

init_comment_helpers() {
  _CH_AGENT="$1"
  _CH_USE_GITHUB="${2:-false}"
  _CH_MARKER="fullsend:${_CH_AGENT}-agent"
  _CH_GH_MARKER="<!-- ${_CH_MARKER} -->"
}

_find_sticky_comment_jira() {
  local key="$1"
  validate_jira_host
  local auth
  auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  curl -sSf \
    -H "Authorization: Basic $auth" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${key}/comment?orderBy=-created&maxResults=50" \
    2>/dev/null \
    | jq -r --arg marker "$_CH_MARKER" \
      '[.comments[] | select(
        [.body.content[]? | .. | .text? // empty] | join(" ") | contains($marker)
      ) | .id] | first // empty'
}

_build_jira_adf_with_history() {
  local new_adf="$1" existing_id="$2" auth="$3"
  local new_content old_body old_current old_history timestamp history_entry final_adf

  new_content=$(echo "$new_adf" | jq '.body.content')

  old_body=$(curl -sSf \
    -H "Authorization: Basic $auth" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment/${existing_id}" \
    2>/dev/null | jq '.body // empty')

  if [[ -z "$old_body" || "$old_body" == "null" ]]; then
    echo "$new_adf"
    return
  fi

  old_current=$(echo "$old_body" | jq '[.content[]? | select(.type != "expand")]')
  old_history=$(echo "$old_body" | jq --argjson max "$((_CH_MAX_HISTORY - 1))" \
    '[.content[]? | select(.type == "expand" and (.attrs.title // "" | startswith("Previous")))] | .[:$max]')

  timestamp=$(date -u +"%b %d, %H:%M UTC")

  history_entry=$(jq -n --argjson content "$old_current" --arg title "Previous · ${timestamp}" \
    '{"type": "expand", "attrs": {"title": $title}, "content": $content}')

  final_adf=$(jq -n \
    --argjson new_content "$new_content" \
    --argjson history_entry "$history_entry" \
    --argjson old_history "$old_history" \
    --arg marker "$_CH_MARKER" \
    '{body: {type: "doc", version: 1, content:
      ($new_content
       + [{"type": "rule"}]
       + [$history_entry]
       + $old_history
       + [{"type": "expand", "attrs": {"title": ""}, "content":
           [{"type": "paragraph", "content": [{"type": "text", "text": $marker}]}]}]
      )
    }}')

  echo "$final_adf"
}

_redact_secrets() {
  if command -v fullsend >/dev/null 2>&1; then
    fullsend scan output
  else
    echo "::warning::fullsend not on PATH — posting comment without secret scanning" >&2
    cat
  fi
}

sticky_comment() {
  local body
  body=$(printf '%s' "$1" | _redact_secrets)

  if $_CH_USE_GITHUB; then
    printf '%s' "$body" | fullsend post-comment \
      --repo "${REPO_FULL_NAME}" \
      --number "${GITHUB_ISSUE_NUMBER}" \
      --marker "${_CH_GH_MARKER}" \
      --token "${GH_TOKEN}" \
      --result -

  elif [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    local auth
    auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
    local adf_body
    adf_body=$(printf '%s' "$body" | python3 "${SCRIPT_DIR}/markdown-to-adf.py")

    local existing_id
    existing_id=$(_find_sticky_comment_jira "$ISSUE_KEY")

    if [[ -n "$existing_id" ]]; then
      local full_adf
      full_adf=$(_build_jira_adf_with_history "$adf_body" "$existing_id" "$auth")
      if curl -sSf -X PUT \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" \
        -d "$full_adf" \
        "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment/${existing_id}" > /dev/null 2>&1; then
        echo "Updated sticky Jira comment ${existing_id} (history preserved)"
      else
        curl -sSf -X POST \
          -H "Authorization: Basic $auth" \
          -H "Content-Type: application/json" \
          -d "$full_adf" \
          "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment" > /dev/null 2>&1 || true
      fi
    else
      adf_body=$(echo "$adf_body" | jq --arg marker "$_CH_MARKER" '
        .body.content += [{
          "type": "expand",
          "attrs": {"title": ""},
          "content": [{"type": "paragraph", "content": [{"type": "text", "text": $marker}]}]
        }]
      ')
      curl -sSf -X POST \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" \
        -d "$adf_body" \
        "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment" > /dev/null 2>&1 || true
    fi
  fi
}

new_comment() {
  local body
  body=$(printf '%s' "$1" | _redact_secrets)
  if $_CH_USE_GITHUB; then
    printf '%s' "$body" | gh issue comment "$GITHUB_ISSUE_NUMBER" \
      --repo "$REPO_FULL_NAME" --body-file - 2>/dev/null || true
  elif [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    validate_jira_host
    local auth
    auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
    local adf_body
    adf_body=$(printf '%s' "$body" | python3 "${SCRIPT_DIR}/markdown-to-adf.py")
    curl -sSf -X POST \
      -H "Authorization: Basic $auth" \
      -H "Content-Type: application/json" \
      -d "$adf_body" \
      "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment" > /dev/null 2>&1 || true
  fi
}

add_label() {
  local repo="$1" number="$2" label="$3"
  gh api "repos/${repo}/issues/${number}/labels" -f "labels[]=${label}" --silent 2>/dev/null || true
}

remove_label() {
  local repo="$1" number="$2" label="$3"
  local encoded
  encoded=$(printf '%s' "$label" | jq -sRr @uri)
  gh api "repos/${repo}/issues/${number}/labels/${encoded}" -X DELETE --silent 2>/dev/null || true
}
