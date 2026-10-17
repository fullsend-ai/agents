#!/usr/bin/env bash
# shellcheck shell=bash
# github-signed-push.lib.sh — Publish local commits through the GitHub Git
# Data API so GitHub signs them.
#
# The sandbox has no signing key, so a pushed commit is unsigned and a
# ruleset that requires signatures rejects it. GitHub signs the commits it
# creates for an App installation token itself, as long as the request sets
# no author, committer or signature. forge_push_branch rebuilds each commit
# origin lacks (blobs, tree, commit, ref) and moves the local branch onto
# the result.
#
# The rebuilt commit's author is therefore the App's bot user; the sandbox
# identity survives in an `Authored-by: name <email>` trailer, which
# post-fix and the fix-history-rewrite skill read.
#
# Each blob, tree and commit is one content-creating request, against
# GitHub's secondary limit of about 80 per minute and 500 per hour.
#
# Approach prototyped by Hector Martinez Lopez (@rh-hemartin) in
# fullsend-ai/agents#357.
#
# Expected globals:
#   REPO_FULL_NAME — owner/repo
#   PUSH_TOKEN     — GitHub App installation token (GH_TOKEN as fallback)
#   GIT_BOT_EMAIL  — the App bot's noreply address; only a commit it
#                    authored keeps an existing Authored-by trailer
# origin must carry push credentials (forge_set_push_remote) for the final
# fetch.

[[ -n "${GITHUB_SIGNED_PUSH_SH_LOADED:-}" ]] && return 0
GITHUB_SIGNED_PUSH_SH_LOADED=1

_SIGNED_PUSH_ZERO="0000000000000000000000000000000000000000"

# _signed_push_api METHOD PATH PAYLOAD_FILE — prints the response body. PATH
# is relative to the repository, or `graphql`. Retries rate-limit and 5xx
# responses.
_signed_push_api() {
  local method="$1" path="$2" payload="$3"
  local attempt body endpoint err rc
  err="${_SIGNED_PUSH_DIR}/stderr"
  case "${path}" in
    graphql) endpoint="graphql" ;;
    *) endpoint="repos/${REPO_FULL_NAME}/${path}" ;;
  esac
  for attempt in 1 2 3; do
    rc=0
    body="$(GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh api -X "${method}" \
      "${endpoint}" --input "${payload}" 2>"${err}")" || rc=$?
    if [ "${rc}" -eq 0 ]; then
      printf '%s' "${body}"
      return 0
    fi
    if [ "${attempt}" -eq 3 ] || ! grep -qiE 'rate limit|HTTP 5[0-9][0-9]' "${err}"; then
      break
    fi
    sleep $((attempt * 30))
  done
  cat "${err}" >&2
  # gh prints only the top-level message; errors[] names the rule or object.
  printf '%s' "${body}" \
    | jq -r 'select(.message != null) | (.errors // [])[] | .message // tojson' >&2 2>/dev/null
  return 1
}

# _signed_push_blob SHA — uploads the local blob SHA and checks that GitHub
# stored it under the same SHA.
_signed_push_blob() {
  local sha="$1" payload="${_SIGNED_PUSH_DIR}/payload" resp got
  if ! git cat-file blob "${sha}" | base64 | tr -d '\n' \
      | jq -Rs '{content: ., encoding: "base64"}' > "${payload}"; then
    echo "error: could not read blob ${sha}" >&2
    return 1
  fi
  resp="$(_signed_push_api POST git/blobs "${payload}")" || return 1
  got="$(printf '%s' "${resp}" | jq -r '.sha // empty')"
  if [ "${got}" != "${sha}" ]; then
    echo "error: GitHub stored blob ${sha} as '${got}'" >&2
    return 1
  fi
}

# _signed_push_mapped SHA — prints the SHA GitHub created for the local
# commit SHA, or SHA itself when it was not rebuilt (it is on origin).
_signed_push_mapped() {
  awk -v sha="$1" '$1 == sha { print $2; found = 1; exit } END { if (!found) print sha }' \
    "${_SIGNED_PUSH_MAP}"
}

# _signed_push_base_parent COMMIT — prints the parent whose tree differs
# from COMMIT's in the fewest paths, so a merge uploads the smaller side.
# Any parent's tree is already on GitHub (origin, or rebuilt and verified).
_signed_push_base_parent() {
  local commit="$1" parent best="" best_n="" n
  for parent in $(git rev-parse -q "${commit}^@"); do
    n="$(git diff-tree -r --no-renames --raw "${parent}" "${commit}" | wc -l | tr -d ' ')"
    if [ -z "${best}" ] || [ "${n}" -lt "${best_n}" ]; then
      best="${parent}"
      best_n="${n}"
    fi
  done
  [ -n "${best}" ] && echo "${best}"
}

# _signed_push_commit COMMIT — recreates the local COMMIT with every parent
# swapped for the SHA GitHub created for it and prints the SHA of the commit
# GitHub created.
_signed_push_commit() {
  local commit="$1"
  local entries="${_SIGNED_PUSH_DIR}/entries" payload="${_SIGNED_PUSH_DIR}/payload"
  local local_parent base_tree tree new_tree known meta path src_mode dst_mode dst_sha status
  local parent parents author keep resp sha reason
  local_parent="$(_signed_push_base_parent "${commit}")" || {
    echo "error: no commit on origin to build ${commit} on" >&2
    return 1
  }
  base_tree="$(git rev-parse "${local_parent}^{tree}")"
  tree="$(git rev-parse "${commit}^{tree}")"

  # Blobs GitHub already has: the base tree's, and this push's uploads.
  known="${_SIGNED_PUSH_DIR}/known-blobs"
  git ls-tree -r "${base_tree}" | awk '$2 == "blob" { print $3 }' > "${known}"

  # --raw -z entries: ":<src mode> <dst mode> <src sha> <dst sha> <status>\0<path>\0"
  : > "${entries}"
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r src_mode dst_mode _ dst_sha status <<< "${meta#:}"
    if [ "${status}" = "D" ]; then
      jq -nc --arg p "${path}" --arg m "${src_mode}" \
        '{path: $p, mode: $m, type: (if $m == "160000" then "commit" else "blob" end), sha: null}'
    elif [ "${dst_mode}" = "160000" ]; then
      jq -nc --arg p "${path}" --arg s "${dst_sha}" \
        '{path: $p, mode: "160000", type: "commit", sha: $s}'
    else
      if ! grep -qxF "${dst_sha}" "${known}" "${_SIGNED_PUSH_BLOBS}"; then
        _signed_push_blob "${dst_sha}" || return 1
        echo "${dst_sha}" >> "${_SIGNED_PUSH_BLOBS}"
      fi
      jq -nc --arg p "${path}" --arg m "${dst_mode}" --arg s "${dst_sha}" \
        '{path: $p, mode: $m, type: "blob", sha: $s}'
    fi >> "${entries}"
  done < <(git diff-tree -r --no-renames -z --raw "${local_parent}" "${commit}")

  if [ -s "${entries}" ]; then
    jq -sc --arg b "${base_tree}" '{base_tree: $b, tree: .}' "${entries}" > "${payload}"
    resp="$(_signed_push_api POST git/trees "${payload}")" || return 1
    new_tree="$(printf '%s' "${resp}" | jq -r '.sha // empty')"
  else
    new_tree="${base_tree}"
  fi
  if [ "${new_tree}" != "${tree}" ]; then
    echo "error: tree rebuilt for ${commit} is '${new_tree}', expected ${tree}" >&2
    return 1
  fi

  parents="$(for parent in $(git rev-parse "${commit}^@"); do
    _signed_push_mapped "${parent}"
  done | jq -Rn '[inputs]')"
  # The author becomes the App's bot user, so the local identity goes into
  # a trailer. A commit that bot authored came back from GitHub and keeps
  # the trailer it was published with; any other commit loses every
  # Authored-by line first, so a crafted one cannot survive a rebase.
  # interpret-trailers runs outside the checkout so a repo-local
  # trailer.*.cmd cannot run here.
  author="$(git log -1 --format='%an <%ae>' "${commit}")"
  if [[ "${author}" == *"[bot] <${GIT_BOT_EMAIL:-}>" ]]; then
    keep=1
  else
    # shellcheck disable=SC2016  # awk program, not shell expansion
    keep='tolower($0) !~ /^authored-by:/'
  fi
  git cat-file commit "${commit}" | sed '1,/^$/d' | awk "${keep}" \
    | git -C "${_SIGNED_PUSH_DIR}" interpret-trailers --no-divider \
        --if-exists doNothing --trailer "Authored-by: ${author}" \
    > "${payload}.msg" || {
    echo "error: could not read the message of ${commit}" >&2
    return 1
  }
  jq -n --rawfile m "${payload}.msg" --arg t "${tree}" --argjson p "${parents}" \
    '{message: $m, tree: $t, parents: $p}' > "${payload}"
  resp="$(_signed_push_api POST git/commits "${payload}")" || return 1
  sha="$(printf '%s' "${resp}" | jq -r '.sha // empty')"
  if [ -z "${sha}" ]; then
    echo "error: no sha in the commit response" >&2
    return 1
  fi
  if [ "$(printf '%s' "${resp}" | jq -r '.verification.verified')" != "true" ]; then
    reason="$(printf '%s' "${resp}" | jq -r '.verification.reason // "unknown"')"
    # An App installation token always gets a signature; a PAT (eval
    # harness, local runs) never does.
    if [ "${PUSH_TOKEN_SOURCE:-}" = "github-app" ]; then
      echo "error: GitHub did not sign ${sha} (${reason})" >&2
      return 1
    fi
    echo "warning: GitHub did not sign ${sha} (${reason})" >&2
  fi
  echo "${sha}"
}

# _signed_push_repo_id — prints the GraphQL node id of REPO_FULL_NAME.
_signed_push_repo_id() {
  local payload="${_SIGNED_PUSH_DIR}/payload" resp id
  jq -n --arg o "${REPO_FULL_NAME%%/*}" --arg n "${REPO_FULL_NAME#*/}" \
    '{query: "query($o: String!, $n: String!) { repository(owner: $o, name: $n) { id } }",
      variables: {o: $o, n: $n}}' > "${payload}"
  resp="$(_signed_push_api POST graphql "${payload}")" || return 1
  id="$(printf '%s' "${resp}" | jq -r '.data.repository.id // empty')"
  if [ -z "${id}" ]; then
    echo "error: no repository id in the response for ${REPO_FULL_NAME}" >&2
    return 1
  fi
  echo "${id}"
}

# _signed_push_update_ref BRANCH BEFORE AFTER FORCE — moves refs/heads/BRANCH
# from BEFORE (all zeros: create) to AFTER. updateRefs applies it only while
# the ref is still at BEFORE, the compare-and-swap --force-with-lease needs,
# and without FORCE only as a fast-forward. A retried request that had
# already been applied leaves the ref at AFTER, which counts as success.
_signed_push_update_ref() {
  local branch="$1" before="$2" after="$3" force="$4"
  local payload="${_SIGNED_PUSH_DIR}/payload" repo_id current
  repo_id="$(_signed_push_repo_id)" || return 1
  jq -n --arg r "${repo_id}" --arg n "refs/heads/${branch}" \
    --arg b "${before}" --arg a "${after}" --argjson f "${force}" \
    '{query: "mutation($r: ID!, $u: [RefUpdate!]!) { updateRefs(input: {repositoryId: $r, refUpdates: $u}) { clientMutationId } }",
      variables: {r: $r, u: [{name: $n, beforeOid: $b, afterOid: $a, force: $f}]}}' > "${payload}"
  if _signed_push_api POST graphql "${payload}" > /dev/null; then
    return 0
  fi
  current="$(git ls-remote --heads origin "refs/heads/${branch}")" || return 1
  current="${current%%[[:space:]]*}"
  current="${current:-${_SIGNED_PUSH_ZERO}}"
  if [ "${current}" = "${after}" ]; then
    return 0
  fi
  if [ "${current}" != "${before}" ]; then
    echo "error: origin/${branch} moved from ${before} to ${current} (non-fast-forward)" >&2
  fi
  return 1
}

# forge_push_branch BRANCH [--force-with-lease]
#
# Drop-in for `git push -u origin BRANCH`: publishes the current branch's
# commits that origin lacks through the API, updates origin/BRANCH, and
# moves the local branch and its upstream onto the commits GitHub created.
# A non-fast-forward update needs --force-with-lease and, as with git, is
# refused once origin/BRANCH differs from the remote-tracking ref.
forge_push_branch() {
  local rc=0 _SIGNED_PUSH_DIR _SIGNED_PUSH_MAP _SIGNED_PUSH_BLOBS
  _SIGNED_PUSH_DIR="$(mktemp -d)"
  _SIGNED_PUSH_MAP="${_SIGNED_PUSH_DIR}/commits"
  _SIGNED_PUSH_BLOBS="${_SIGNED_PUSH_DIR}/blobs"
  touch "${_SIGNED_PUSH_MAP}" "${_SIGNED_PUSH_BLOBS}"
  _forge_push_branch "$@" || rc=$?
  rm -rf "${_SIGNED_PUSH_DIR}"
  return "${rc}"
}

_forge_push_branch() {
  local branch="$1" mode="${2:-}"
  local remote_sha lease tip commit commits fetched
  remote_sha="$(git ls-remote --heads origin "refs/heads/${branch}")" || {
    echo "error: could not read origin/${branch}" >&2
    return 1
  }
  remote_sha="${remote_sha%%[[:space:]]*}"
  if [ "${mode}" = "--force-with-lease" ]; then
    lease="$(git rev-parse -q --verify "refs/remotes/origin/${branch}")" || {
      echo "error: no remote-tracking ref origin/${branch} to lease on; refusing the non-fast-forward update" >&2
      return 1
    }
  elif [ -n "${remote_sha}" ] \
       && ! { git cat-file -e "${remote_sha}^{commit}" 2>/dev/null \
              && git merge-base --is-ancestor "${remote_sha}" HEAD; }; then
    # A commit this clone has never fetched cannot be an ancestor of HEAD.
    echo "error: origin/${branch} is at ${remote_sha}, not an ancestor of HEAD (non-fast-forward)" >&2
    return 1
  fi

  # Parents before children: each parent is on origin or already rebuilt.
  commits="$(git rev-list --reverse --topo-order HEAD --not --remotes=origin)" || return 1
  tip="$(git rev-parse HEAD)"
  for commit in ${commits}; do
    tip="$(_signed_push_commit "${commit}")" || return 1
    echo "Created signed commit ${tip} for ${commit}"
    echo "${commit} ${tip}" >> "${_SIGNED_PUSH_MAP}"
  done

  if [ "${mode}" = "--force-with-lease" ]; then
    _signed_push_update_ref "${branch}" "${lease}" "${tip}" true || return 1
  elif [ "${remote_sha}" = "${tip}" ]; then
    echo "Everything up-to-date"
  else
    _signed_push_update_ref "${branch}" "${remote_sha:-${_SIGNED_PUSH_ZERO}}" "${tip}" false || return 1
  fi

  # The push is complete once the ref moved; failing to move the local
  # branch is a warning, not a failed push.
  git fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" || {
    echo "warning: origin/${branch} is at ${tip} but could not be fetched; the local branch was not moved" >&2
    return 0
  }
  fetched="$(git rev-parse "refs/remotes/origin/${branch}")"
  if [ "${fetched}" != "${tip}" ]; then
    echo "warning: origin/${branch} is at ${fetched} right after the update to ${tip}; the local branch was not moved" >&2
    return 0
  fi
  git reset -q --soft "${tip}" || return 1
  git branch -q --set-upstream-to="origin/${branch}" || return 1
  echo "Branch ${branch} is at ${tip} on origin"
}
