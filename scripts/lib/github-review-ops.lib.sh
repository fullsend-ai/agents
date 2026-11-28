#!/usr/bin/env bash
# shellcheck shell=bash
# github-review-ops.lib.sh — GitHub forge operations for review scripts.
#
# Bundled into pre-review.sh and post-review.sh via review-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by forge_parse_pr_url):
#   REPO         — owner/repo (e.g., "org/repo")
#   PR_NUMBER    — PR number
#
# Expected env vars:
#   PR_URL       — HTML URL of the pull request
#   REVIEW_TOKEN — GitHub token with pull-requests read/write scope

[[ -n "${GITHUB_REVIEW_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_REVIEW_OPS_SH_LOADED=1

# shellcheck source=github-host.lib.sh
source "${BASH_SOURCE[0]%/*}/github-host.lib.sh"

# --- URL handling ---

forge_validate_pr_url() {
  local path
  if ! path=$(_github_url_path "${PR_URL}") \
    || [[ ! "${path}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/pull/[0-9]+$ ]]; then
    echo "ERROR: PR_URL does not match expected GitHub pattern: $(_gha_sanitize "${PR_URL}")" >&2
    return 1
  fi
}

forge_parse_pr_url() {
  REPO=$(_github_url_path "${PR_URL}" | sed 's|/pull/.*||')
  PR_NUMBER=$(basename "${PR_URL}")
}

# --- PR queries ---

forge_get_pr_state() {
  GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json state --jq '.state' 2>/dev/null || true
}

forge_get_pr_author() {
  GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json author --jq '.author.login' 2>/dev/null || true
}

# Fails when the labels cannot be read.
forge_get_pr_labels() {
  GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json labels --jq '.labels[].name' 2>/dev/null
}

forge_get_pr_info() {
  GH_TOKEN="${REVIEW_TOKEN}" gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" --json state,isDraft 2>/dev/null || {
    jq -n '{state: "UNKNOWN", isDraft: false}'
    return
  }
}

forge_get_pr_files() {
  # Use the paginated /pulls/{n}/files REST endpoint rather than the
  # `gh pr view --json files` summary field: issue #2093 found empty
  # results correlated with recent merge-commit updates and hypothesized
  # asynchronous diff computation, but GitHub does not document that as
  # an API contract. The files endpoint reflects the computed diff more
  # directly.
  local files
  if ! files=$(GH_TOKEN="${REVIEW_TOKEN}" gh api \
    "repos/${REPO}/pulls/${PR_NUMBER}/files" --paginate --jq '.[].filename' 2>/dev/null); then
    return 1
  fi
  [[ -n "${files}" ]] && printf '%s\n' "${files}"
}

# --- PR mutations ---

forge_post_review() {
  local result_file="$1"
  fullsend post-review \
    --forge github \
    --repo "${REPO}" \
    --pr "${PR_NUMBER}" \
    --token "${REVIEW_TOKEN}" \
    --result "${result_file}"
}

forge_close_pr() {
  local comment="$1"
  GH_TOKEN="${REVIEW_TOKEN}" gh pr close "${PR_NUMBER}" \
    --repo "${REPO}" \
    --comment "${comment}" || true
}

# --- Comments ---

forge_post_comment() {
  local body="$1"
  printf '%s' "${body}" | GH_TOKEN="${REVIEW_TOKEN}" gh issue comment "${PR_NUMBER}" \
    --repo "${REPO}" --body-file -
}

forge_get_recent_redispatch_comments() {
  local marker="$1"
  local window_seconds="$2"
  GH_TOKEN="${REVIEW_TOKEN}" gh api \
    "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    --paginate 2>/dev/null \
    | jq -s --arg marker "${marker}" --argjson window "${window_seconds}" \
    'add // [] | [.[] | select(.body | contains($marker))
          | select(.created_at > (now - $window | strftime("%Y-%m-%dT%H:%M:%SZ")))]
     | length'
}

# Return a JSON object mapping finding ids to the review-comment URL of the
# review agent's original inline comment. This is best-effort context for
# carried blockers; the ledger itself remains metadata-only. Only comments
# authored by the current viewer are considered, so a human cannot forge a
# finding link by mentioning an id in a reply.
forge_get_finding_comment_links() {
  local owner name query cursor has_next page response page_nodes nodes_json links
  local -a gh_args

  owner="${REPO%%/*}"
  name="${REPO##*/}"
  cursor=""
  has_next="true"
  page=0
  nodes_json="[]"

  query='query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            comments(first: 100) {
              pageInfo { hasNextPage }
              nodes { body viewerDidAuthor url }
            }
          }
        }
      }
    }
  }'

  while [[ "${has_next}" == "true" ]]; do
    page=$((page + 1))
    if [[ "${page}" -gt 20 ]]; then
      echo "::warning::Review thread pagination hit page cap — finding links may be incomplete" >&2
      break
    fi

    gh_args=(api graphql
      -f owner="${owner}"
      -f name="${name}"
      -F number="${PR_NUMBER}"
      -f query="${query}")
    if [[ -n "${cursor}" ]]; then
      gh_args+=(-f cursor="${cursor}")
    fi

    if ! response=$(GH_TOKEN="${REVIEW_TOKEN}" gh "${gh_args[@]}" 2>/dev/null); then
      echo "::warning::Failed to fetch review threads — blocking finding links unavailable" >&2
      echo '{}'
      return 0
    fi
    if echo "${response}" | jq -e '.errors | type == "array" and length > 0' >/dev/null 2>&1; then
      echo "::warning::Review thread query returned errors — blocking finding links unavailable" >&2
      echo '{}'
      return 0
    fi

    page_nodes=$(echo "${response}" | jq -c '.data.repository.pullRequest.reviewThreads.nodes // []' 2>/dev/null) || {
      echo "::warning::Failed to parse review threads — blocking finding links unavailable" >&2
      echo '{}'
      return 0
    }
    nodes_json=$(jq -c --argjson page "${page_nodes}" '. + $page' <<< "${nodes_json}" 2>/dev/null) || {
      echo "::warning::Failed to merge review thread pages — blocking finding links unavailable" >&2
      echo '{}'
      return 0
    }

    has_next=$(echo "${response}" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null) || has_next="false"
    cursor=$(echo "${response}" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' 2>/dev/null) || cursor=""
    if [[ "${has_next}" == "true" && -z "${cursor}" ]]; then
      echo "::warning::Review thread page missing cursor — blocking finding links may be incomplete" >&2
      break
    fi
  done

  links=$(jq -c --arg base "${PR_URL}" '
    [ .[]
      | (.comments.nodes // [])[]
      | select(.viewerDidAuthor == true)
      | . as $comment
      | (($comment.body // "") | scan("finding:(f_[A-Za-z0-9]+)") | .[0]) as $id
      | select(($id | type) == "string")
      | select(($comment.url // "") | startswith($base + "#discussion_r"))
      | select(($comment.url // "") | test("#discussion_r[0-9]+$"))
      | {id: $id, url: $comment.url}
    ]
    | reduce .[] as $match ({}; .[$match.id] //= $match.url)
  ' <<< "${nodes_json}" 2>/dev/null) || links='{}'
  jq -e 'type == "object"' <<< "${links}" >/dev/null 2>&1 || links='{}'
  printf '%s\n' "${links}"
}

# --- Review threads ---

# Select GitHub review-thread node IDs that are safe to auto-resolve.
# Reads a JSON array of reviewThreads.nodes from stdin; prints one ID per line.
#
# A thread is eligible when all of the following hold:
#   - still unresolved
#   - the viewer can resolve it
#   - the thread is outdated (the diff position no longer exists)
#   - every fetched comment is outdated and authored by the viewer
#     (human / other-bot comments are left alone, even if outdated)
#   - there is at least one comment
#   - comment pagination is complete — an incomplete page might hide a
#     human comment, so skip rather than guess
_select_outdated_review_thread_ids() {
  jq -r '
    .[]
    | select(.id != null)
    | select(.isResolved == false)
    | select(.viewerCanResolve == true)
    | select(.isOutdated == true)
    | select((.comments.pageInfo.hasNextPage // false) == false)
    | select((.comments.nodes // [] | length) > 0)
    | select(.comments.nodes // [] | all(.outdated == true))
    | select(.comments.nodes // [] | all(.viewerDidAuthor == true))
    | .id
  '
}

# Resolve still-open review threads whose only comments are outdated
# inline comments authored by this token (the review agent). Best-effort:
# fetch or mutation failures log a warning and return success so they
# cannot block posting the new review.
forge_resolve_outdated_review_threads() {
  local owner name query mutation
  local cursor has_next page response page_nodes nodes_json ids
  local id resolved failed
  local -a gh_args

  owner="${REPO%%/*}"
  name="${REPO##*/}"
  cursor=""
  has_next="true"
  page=0
  nodes_json="[]"
  resolved=0
  failed=0

  query='query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            isOutdated
            viewerCanResolve
            comments(first: 100) {
              pageInfo { hasNextPage }
              nodes {
                outdated
                viewerDidAuthor
              }
            }
          }
        }
      }
    }
  }'

  mutation='mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { isResolved }
    }
  }'

  while [[ "${has_next}" == "true" ]]; do
    page=$((page + 1))
    if [[ "${page}" -gt 20 ]]; then
      echo "::warning::Review thread pagination hit page cap — remaining threads skipped"
      break
    fi

    gh_args=(api graphql
      -f owner="${owner}"
      -f name="${name}"
      -F number="${PR_NUMBER}"
      -f query="${query}")
    if [[ -n "${cursor}" ]]; then
      gh_args+=(-f cursor="${cursor}")
    fi

    if ! response=$(GH_TOKEN="${REVIEW_TOKEN}" gh "${gh_args[@]}" 2>/dev/null); then
      echo "::warning::Failed to fetch review threads — skipping outdated-thread resolution"
      return 0
    fi

    if echo "${response}" | jq -e '.errors | type == "array" and length > 0' >/dev/null 2>&1; then
      echo "::warning::Review thread query returned errors — skipping outdated-thread resolution"
      return 0
    fi

    page_nodes=$(echo "${response}" | jq -c '.data.repository.pullRequest.reviewThreads.nodes // []' 2>/dev/null) || {
      echo "::warning::Failed to parse review threads — skipping outdated-thread resolution"
      return 0
    }
    nodes_json=$(jq -c --argjson page "${page_nodes}" '. + $page' <<< "${nodes_json}" 2>/dev/null) || {
      echo "::warning::Failed to merge review thread pages — skipping outdated-thread resolution"
      return 0
    }

    has_next=$(echo "${response}" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null) || has_next="false"
    cursor=$(echo "${response}" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' 2>/dev/null) || cursor=""
    if [[ "${has_next}" == "true" && -z "${cursor}" ]]; then
      echo "::warning::Review thread page missing cursor — stopping pagination"
      break
    fi
  done

  ids=$(echo "${nodes_json}" | _select_outdated_review_thread_ids 2>/dev/null) || ids=""
  if [[ -z "${ids}" ]]; then
    return 0
  fi

  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue
    if GH_TOKEN="${REVIEW_TOKEN}" gh api graphql \
      -f threadId="${id}" \
      -f query="${mutation}" >/dev/null 2>&1; then
      resolved=$((resolved + 1))
    else
      failed=$((failed + 1))
      echo "::warning::Failed to resolve review thread $(_gha_sanitize "${id}")"
    fi
  done <<< "${ids}"

  if [[ "${resolved}" -gt 0 ]]; then
    echo "Resolved ${resolved} outdated review-agent thread(s)"
  fi
  if [[ "${failed}" -gt 0 ]]; then
    echo "::warning::Failed to resolve ${failed} outdated review thread(s)"
  fi
  return 0
}

# --- Finding threads ---
#
# Normalized thread shape shared with gitlab-review-ops.lib.sh and read by
# forge_reconcile_finding_threads in review-ops.lib.sh:
#   {id, url, resolved, can_resolve, comments_complete,
#    comments: [{body, review_bot, own}]}
# can_resolve is GitLab-only (whether the discussion is resolvable at all).
# GitHub threads omit it: viewerCanResolve is an unreliable proxy for bot
# tokens, so the resolve mutation's response decides instead.
# review_bot: written by a trusted review-bot login (a Bot account), the same
# logins post-review trusts for stamps. own: written by this token's own Bot
# account, so a person's PAT never makes their replies count as the bot's.

_FINDING_THREAD_FIELDS='id isResolved
  comments(first: 100) {
    pageInfo { hasNextPage }
    nodes { url body viewerDidAuthor author { __typename login } }
  }'

# Run a jq program with norm (raw GraphQL thread -> normalized thread) in
# scope. $1 is the program; any further arguments go to jq.
_github_finding_thread_jq() {
  local program="$1"
  shift
  jq -c --arg org "${REPO%%/*}" --arg app_set "${FULLSEND_APP_SET:-}" "$@" '
    ([ ($org + "-review"), ($org + "-review[bot]"),
       "fullsend-ai-review", "fullsend-ai-review[bot]",
       (if $app_set == "" then empty else ($app_set + "-review"), ($app_set + "-review[bot]") end)
     ] | map(ascii_downcase)) as $trusted
    | def norm:
        if type != "object" or (.id | type) != "string" then null else
        {
          id,
          url: ((.comments.nodes // [])[0].url // ""),
          resolved: (.isResolved == true),
          comments_complete: ((.comments.pageInfo.hasNextPage // false) == false),
          comments: [ (.comments.nodes // [])[] | select(type == "object")
                      | (.author.__typename // "") as $type
                      | {
                          body: (.body // ""),
                          review_bot: ($type == "Bot" and (((.author.login // "") | ascii_downcase) as $a | ($trusted | index($a)) != null)),
                          own: (.viewerDidAuthor == true and $type == "Bot")
                        } ]
        } end;
    '"${program}"
}

# Print {complete, head_sha, threads} for every review thread on the PR.
# Fails when a page cannot be read; a page cap or missing cursor reports
# complete: false instead.
forge_fetch_finding_threads() {
  local owner name query cursor has_next page response nodes_json head complete
  local -a gh_args

  owner="${REPO%%/*}"
  name="${REPO##*/}"
  cursor=""
  has_next="true"
  page=0
  nodes_json="[]"
  head=""
  complete=true

  query='query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        headRefOid
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes { '"${_FINDING_THREAD_FIELDS}"' }
        }
      }
    }
  }'

  while [[ "${has_next}" == "true" ]]; do
    page=$((page + 1))
    if [[ "${page}" -gt 20 ]]; then
      complete=false
      break
    fi
    gh_args=(api graphql -f owner="${owner}" -f name="${name}" -F number="${PR_NUMBER}" -f query="${query}")
    if [[ -n "${cursor}" ]]; then
      gh_args+=(-f cursor="${cursor}")
    fi
    response=$(GH_TOKEN="${REVIEW_TOKEN}" gh "${gh_args[@]}" 2>/dev/null) || return 1
    jq -e '(.errors | type == "array" and length > 0) | not' <<< "${response}" >/dev/null 2>&1 || return 1
    jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' <<< "${response}" >/dev/null 2>&1 || return 1
    nodes_json=$(jq -c --argjson acc "${nodes_json}" '$acc + .data.repository.pullRequest.reviewThreads.nodes' <<< "${response}") || return 1
    head=$(jq -r '.data.repository.pullRequest.headRefOid // empty' <<< "${response}")
    has_next=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' <<< "${response}")
    cursor=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' <<< "${response}")
    if [[ "${has_next}" == "true" && -z "${cursor}" ]]; then
      complete=false
      break
    fi
  done

  _github_finding_thread_jq \
    '{complete: $complete, head_sha: $head, threads: [ .[] | norm | select(. != null) ]}' \
    --arg head "${head}" --argjson complete "${complete}" <<< "${nodes_json}"
}

# Print {head_sha, thread} for one thread, re-read just before acting on it.
# thread is null when the thread no longer exists. Fails when it cannot be read.
forge_fetch_finding_thread() {
  local thread_id="$1" query response
  query='query($threadId: ID!) {
    node(id: $threadId) {
      ... on PullRequestReviewThread {
        pullRequest { headRefOid }
        '"${_FINDING_THREAD_FIELDS}"'
      }
    }
  }'
  response=$(GH_TOKEN="${REVIEW_TOKEN}" gh api graphql -f threadId="${thread_id}" -f query="${query}" 2>/dev/null) || return 1
  jq -e '(.errors | type == "array" and length > 0) | not' <<< "${response}" >/dev/null 2>&1 || return 1
  _github_finding_thread_jq \
    '.data.node as $n | {head_sha: ($n.pullRequest.headRefOid // ""), thread: ($n | norm)}' \
    <<< "${response}"
}

forge_reply_finding_thread() {
  local thread_id="$1" body="$2" response
  response=$(GH_TOKEN="${REVIEW_TOKEN}" gh api graphql \
    -f threadId="${thread_id}" \
    -f body="${body}" \
    -f query='mutation($threadId: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
        comment { id }
      }
    }' 2>/dev/null) || return 1
  jq -e '(.errors | type == "array" and length > 0) | not' <<< "${response}" >/dev/null 2>&1
}

forge_resolve_finding_thread() {
  local thread_id="$1" response
  response=$(GH_TOKEN="${REVIEW_TOKEN}" gh api graphql \
    -f threadId="${thread_id}" \
    -f query='mutation($threadId: ID!) {
      resolveReviewThread(input: {threadId: $threadId}) {
        thread { isResolved }
      }
    }' 2>/dev/null) || return 1
  jq -e '(.errors | type == "array" and length > 0) | not' <<< "${response}" >/dev/null 2>&1
}

# --- Human dismissals ---

# --- Labels ---

forge_add_label() {
  local label="$1"
  GH_TOKEN="${REVIEW_TOKEN}" gh api "repos/${REPO}/issues/${PR_NUMBER}/labels" \
    -f "labels[]=${label}" --silent || \
    echo "::warning::Failed to add label '$(_gha_sanitize "${label}")'"
}

forge_remove_label() {
  local label="$1"
  local encoded
  encoded=$(printf '%s' "${label}" | jq -sRr @uri)
  GH_TOKEN="${REVIEW_TOKEN}" gh api "repos/${REPO}/issues/${PR_NUMBER}/labels/${encoded}" \
    -X DELETE --silent 2>/dev/null || true
}

# Succeeds when the label is gone afterwards; 404 means it was already absent.
forge_remove_label_checked() {
  local label="$1"
  local encoded err
  encoded=$(printf '%s' "${label}" | jq -sRr @uri)
  err=$(GH_TOKEN="${REVIEW_TOKEN}" gh api "repos/${REPO}/issues/${PR_NUMBER}/labels/${encoded}" \
    -X DELETE --silent 2>&1) && return 0
  [[ "${err}" == *"HTTP 404"* ]]
}

forge_remove_label_edit() {
  local label="$1"
  GH_TOKEN="${REVIEW_TOKEN}" gh pr edit "${PR_NUMBER}" --repo "${REPO}" \
    --remove-label "${label}" 2>/dev/null || true
}

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  GH_TOKEN="${REVIEW_TOKEN}" gh label create "${name}" --repo "${REPO}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

forge_add_label_edit() {
  local label="$1"
  GH_TOKEN="${REVIEW_TOKEN}" gh pr edit "${PR_NUMBER}" --repo "${REPO}" \
    --add-label "${label}" || true
}

forge_list_repo_labels() {
  GH_TOKEN="${REVIEW_TOKEN}" gh api "repos/${REPO}/labels" --paginate --jq '.[].name' 2>/dev/null || true
}
