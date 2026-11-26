#!/usr/bin/env bash
# shellcheck shell=bash
# github-fix-ops.lib.sh — GitHub forge operations for fix agent scripts.
#
# Bundled into pre-fix.sh and post-fix.sh via fix-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by caller):
#   REPO_FULL_NAME — owner/repo (e.g., "org/repo")
#   PR_NUMBER      — pull request number
#
# Expected env vars:
#   GH_TOKEN       — GitHub token with appropriate scopes

[[ -n "${GITHUB_FIX_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_FIX_OPS_SH_LOADED=1

# forge_push_branch: a plain git push, or with GITHUB_SIGNED_COMMITS=true the
# API publish that gets the commits signed by GitHub.
# shellcheck source=github-signed-push.lib.sh
source "${BASH_SOURCE[0]%/*}/github-signed-push.lib.sh"
# shellcheck source=github-host.lib.sh
source "${BASH_SOURCE[0]%/*}/github-host.lib.sh"

if ! declare -F gha_echo >/dev/null 2>&1; then
  gha_echo() {
    local lvl="$1"; shift
    local msg="${*//::/ }"
    msg="${msg//%0A/}"; msg="${msg//%0a/}"
    msg="${msg//%0D/}"; msg="${msg//%0d/}"
    printf '::%s::%s\n' "${lvl}" "${msg}"
  }
fi

# --- PR/MR operations ---

forge_validate_pr_url() {
  local url="${1:-${PR_URL:-}}" path
  if ! path=$(_github_url_path "${url}") \
    || [[ ! "${path}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/pull/[1-9][0-9]*$ ]]; then
    echo "ERROR: PR_URL does not match expected GitHub pattern: ${url}" >&2
    return 1
  fi
}

forge_parse_pr_url() {
  local url="${1:-${PR_URL:-}}"
  REPO_FULL_NAME=$(_github_url_path "${url}" | sed 's|/pull/.*||')
  # shellcheck disable=SC2034
  PR_NUMBER=$(basename "${url}")
}

forge_get_pr_head_ref() {
  local pr_number="$1"
  GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json headRefName --jq '.headRefName' 2>/dev/null
}

# forge_get_pr_base_branch PR_NUMBER — PR base branch (not the repo default).
# Empty on API failure; callers fall back to TARGET_BRANCH / main.
forge_get_pr_base_branch() {
  local pr_number="$1"
  GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json baseRefName --jq '.baseRefName // empty' 2>/dev/null
}

# forge_get_pr_merge_state PR_NUMBER — GitHub GraphQL MergeableState
# (MERGEABLE | CONFLICTING | UNKNOWN). Prints "unknown" on API failure or
# empty response so callers never treat a missing signal as a conflict.
forge_get_pr_merge_state() {
  local pr_number="$1"
  local mergeable
  mergeable="$(GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json mergeable --jq '.mergeable // empty' 2>/dev/null)" || {
    echo "unknown"
    return 0
  }
  if [ -z "${mergeable}" ]; then
    echo "unknown"
    return 0
  fi
  echo "${mergeable}"
}

# forge_pr_has_merge_conflict PR_NUMBER — return 0 only when GitHub reports
# mergeable=CONFLICTING. BLOCKED / BEHIND / UNSTABLE / UNKNOWN / MERGEABLE
# and API failures are not conflicts (issue #1518).
forge_pr_has_merge_conflict() {
  local pr_number="$1"
  local mergeable
  mergeable="$(forge_get_pr_merge_state "${pr_number}")" || return 1
  [ "${mergeable}" = "CONFLICTING" ]
}

# forge_get_pr_labels PR_NUMBER — the PR's live label names, one per line.
# Returns non-zero on API failure so callers can tell it apart from a PR
# with no labels.
forge_get_pr_labels() {
  local pr_number="$1"
  GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json labels --jq '.labels[].name' 2>/dev/null
}

# --- Push operations ---

forge_set_push_remote() {
  local token="$1" server
  server=$(_github_server_url) || return 1
  git remote set-url origin \
    "https://x-access-token:${token}@${server#https://}/${REPO_FULL_NAME}.git"
}

forge_setup_push_token() {
  local token="$1"
  export GH_TOKEN="${token}"
}

forge_mask_token() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    local token="${1:-${GH_TOKEN:-}}"
    echo "::add-mask::${token}"
  fi
}

# --- Label operations ---

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  gh label create "${name}" --repo "${REPO_FULL_NAME}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

forge_add_pr_label() {
  local pr_number="$1"
  local label="$2"
  gh pr edit "${pr_number}" --repo "${REPO_FULL_NAME}" \
    --add-label "${label}" 2>/dev/null || true
}

# --- Comment operations ---

forge_post_pr_comment() {
  local pr_number="$1"
  local body="$2"
  gh pr comment "${pr_number}" \
    --repo "${REPO_FULL_NAME}" \
    --body "${body}"
}

# --- Workspace operations ---

forge_get_workflow_run_url() {
  local run_repo="${GITHUB_REPOSITORY:-${REPO_FULL_NAME}}"
  printf '%s/%s/actions/runs/%s' \
    "${GITHUB_SERVER_URL:-https://github.com}" \
    "${run_repo}" \
    "${GITHUB_RUN_ID:-unknown}"
}

forge_get_workspace_dir() {
  echo "${GITHUB_WORKSPACE:-}"
}

forge_append_path() {
  local dir="$1"
  echo "${dir}" >> "${GITHUB_PATH:-/dev/null}"
}

# --- Finding threads ---

# finding_threads_manifest_path — where pre-fix writes the finding-thread
# manifest and post-fix reads it back (issue #2187). harness/fix.yaml mounts
# the same path into the sandbox as /sandbox/workspace/finding-threads.json.
# Fails when RUNNER_TEMP is unset (outside GitHub Actions).
finding_threads_manifest_path() {
  [[ -n "${RUNNER_TEMP:-}" ]] || return 1
  printf '%s/fullsend-fix-finding-threads.json\n' "${RUNNER_TEMP}"
}

# _finding_threads_manifest_from_nodes COMPLETE HEAD_SHA — reads a JSON array
# of reviewThreads.nodes on stdin and prints the manifest. A thread is listed
# when it is unresolved and its first comment is a trusted review-bot comment
# carrying exactly one <!-- finding:f_... --> stamp. Every comment in the
# thread is kept, human replies included. Trusted review bots are
# <org>-review, fullsend-ai-review and, when FULLSEND_APP_SET is set,
# <app-set>-review (the same identities post-review trusts).
_finding_threads_manifest_from_nodes() {
  local complete="$1" head_sha="$2"
  jq -c --argjson complete "${complete}" --arg head "${head_sha}" \
    --arg org "${REPO_FULL_NAME%%/*}" --arg app_set "${FULLSEND_APP_SET:-}" '
    ([ ($org + "-review"), ($org + "-review[bot]"),
       "fullsend-ai-review", "fullsend-ai-review[bot]",
       (if $app_set == "" then empty else ($app_set + "-review"), ($app_set + "-review[bot]") end)
     ] | map(ascii_downcase)) as $trusted
    | def review_bot:
        (.author.__typename // "") == "Bot"
        and (((.author.login // "") | ascii_downcase) as $l | ($trusted | index($l)) != null);
    [ .[]
      | select(type == "object" and .isResolved == false)
      | (.comments.nodes // [] | map(select(type == "object"))) as $cs
      | select(($cs | length) > 0)
      | select($cs[0] | review_bot)
      | ([ $cs[0].body // "" | scan("<!--[[:space:]]+finding:(f_[A-Za-z0-9]+)[[:space:]]+-->") | .[0] ] | unique) as $ids
      | select(($ids | length) == 1)
      | {
          finding_id: $ids[0],
          url: ($cs[0].url // ""),
          path: .path,
          line: .line,
          is_outdated: (.isOutdated == true),
          comments_complete: ((.comments.pageInfo.hasNextPage // false) | not),
          comments: [ $cs[] | {
            id: .databaseId,
            author: (.author.login // "ghost"),
            review_bot: review_bot,
            created_at: .createdAt,
            url: .url,
            body: (.body // "")
          } ]
        }
    ] as $threads
    | ([ $threads | group_by(.finding_id)[] | select(length > 1) | .[0].finding_id ]) as $dups
    | {
        complete: $complete,
        head_sha: $head,
        threads: [ $threads[] | . + {ambiguous: (.finding_id as $f | ($dups | index($f)) != null)} ]
      }
  '
}

# forge_write_finding_threads_manifest PATH — write the open review-bot
# finding threads of the PR to PATH for the fix agent (issue #2187).
# Best-effort: a failed or truncated fetch writes a manifest with
# complete=false (and whatever threads were read) and still succeeds, so the
# run is never blocked on it.
forge_write_finding_threads_manifest() {
  local out="$1"
  local owner name query cursor has_next page response page_nodes nodes_json
  local head_sha complete tmp
  local -a gh_args

  owner="${REPO_FULL_NAME%%/*}"
  name="${REPO_FULL_NAME##*/}"
  cursor=""
  has_next="true"
  page=0
  nodes_json="[]"
  head_sha=""
  complete="true"

  query='query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        headRefOid
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            isResolved
            isOutdated
            path
            line
            comments(first: 100) {
              pageInfo { hasNextPage }
              nodes {
                databaseId
                url
                body
                createdAt
                author { __typename login }
              }
            }
          }
        }
      }
    }
  }'

  while [[ "${has_next}" == "true" ]]; do
    page=$((page + 1))
    if [[ "${page}" -gt 20 ]]; then
      gha_echo warning "Review thread pagination hit page cap — finding-thread manifest is incomplete"
      complete="false"
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
    if ! response="$(GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh "${gh_args[@]}" 2>/dev/null)" \
      || ! jq -e '(.errors // []) == [] and (.data.repository.pullRequest.reviewThreads.nodes | type) == "array"' \
        <<< "${response}" >/dev/null 2>&1; then
      gha_echo warning "Could not read review threads — finding-thread manifest is incomplete"
      complete="false"
      break
    fi
    page_nodes="$(jq -c '.data.repository.pullRequest.reviewThreads.nodes' <<< "${response}")"
    nodes_json="$(jq -c --argjson page "${page_nodes}" '. + $page' <<< "${nodes_json}")"
    head_sha="$(jq -r '.data.repository.pullRequest.headRefOid // empty' <<< "${response}")"
    has_next="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' <<< "${response}")"
    cursor="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' <<< "${response}")"
    if [[ "${has_next}" == "true" && -z "${cursor}" ]]; then
      gha_echo warning "Review thread page missing cursor — finding-thread manifest is incomplete"
      complete="false"
      break
    fi
  done

  tmp="$(mktemp "${out}.XXXXXX")" || return 0
  if _finding_threads_manifest_from_nodes "${complete}" "${head_sha}" <<< "${nodes_json}" > "${tmp}" \
    && mv -f "${tmp}" "${out}"; then
    echo "Wrote finding-thread manifest: $(jq '.threads | length' "${out}") open thread(s), complete=${complete}"
  else
    rm -f "${tmp}"
    gha_echo warning "Could not write the finding-thread manifest"
  fi
  return 0
}
