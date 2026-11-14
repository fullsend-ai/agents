#!/usr/bin/env bash
# fake-gh-git-api.sh — stand-in for the `gh api` calls that
# scripts/lib/github-signed-push.lib.sh makes. Serves them from the bare
# repository behind the checkout's origin remote with git plumbing, so tests
# exercise the signed push without GitHub.
#
# Wire it from a mock gh:   "api -X") exec bash "${FAKE_GH_GIT_API}" "$@" ;;
#
# Knobs:
#   FAKE_GH_UNVERIFIED=1      report verification.verified=false
#   FAKE_GH_CORRUPT_BLOB=1    answer blob uploads with a wrong SHA
#   FAKE_GH_FAIL_ONCE=<file>  fail the first request with HTTP 502, create
#                             <file>, then serve normally
#   FAKE_GH_RACE=<ref>=<sha>  move <ref> to <sha> on the first commit
#                             request, like a concurrent push
#   FAKE_GH_REF_APPLIED_502=<file>
#                             apply the first ref update, then answer it
#                             with HTTP 502 and create <file>
#   FAKE_GH_MOVE_AFTER_UPDATE=<ref>=<sha>
#                             move <ref> to <sha> right after a ref update
#   FAKE_GH_BLOB_LOG=<file>   append the SHA of every uploaded blob to <file>
#   FAKE_GH_REJECT_COMMITS=1  answer commit creation with a rule-violation
#                             error whose body names the rule
set -euo pipefail

# gh api -X METHOD repos/OWNER/REPO/<endpoint> --input FILE
# gh api -X POST graphql --input FILE
method="$3"
endpoint="${4#repos/*/*/}"
input="$6"
bare="$(git remote get-url origin)"
bare="${bare#file://}"
zero="0000000000000000000000000000000000000000"
g() { git --git-dir="${bare}" "$@"; }

if [ -n "${FAKE_GH_FAIL_ONCE:-}" ] && [ ! -e "${FAKE_GH_FAIL_ONCE}" ]; then
  : > "${FAKE_GH_FAIL_ONCE}"
  echo "gh: Bad Gateway (HTTP 502)" >&2
  exit 1
fi

case "${method} ${endpoint}" in
  "POST git/blobs")
    if [ -n "${FAKE_GH_CORRUPT_BLOB:-}" ]; then
      sha="0000000000000000000000000000000000000000"
    else
      sha="$(jq -r '.content' "${input}" | base64 -d | g hash-object -w --stdin)"
    fi
    if [ -n "${FAKE_GH_BLOB_LOG:-}" ]; then
      echo "${sha}" >> "${FAKE_GH_BLOB_LOG}"
    fi
    jq -n --arg s "${sha}" '{sha: $s}'
    ;;
  "POST git/trees")
    index="$(mktemp -u)"
    GIT_INDEX_FILE="${index}" g read-tree "$(jq -r '.base_tree' "${input}")"
    # A null sha deletes the path; mode 0 is how --index-info spells that.
    jq -r '.tree[] | (if .sha == null then "0 0000000000000000000000000000000000000000"
                      else "\(.mode) \(.sha)" end) + "\t" + .path' "${input}" \
      | GIT_INDEX_FILE="${index}" g update-index --index-info
    sha="$(GIT_INDEX_FILE="${index}" g write-tree)"
    rm -f "${index}"
    jq -n --arg s "${sha}" '{sha: $s}'
    ;;
  "POST git/commits")
    if [ -n "${FAKE_GH_REJECT_COMMITS:-}" ]; then
      echo '{"message":"Repository rule violations found","errors":[{"resource":"Commit","code":"custom","message":"Commits must have verified signatures."}]}'
      echo "gh: Repository rule violations found (HTTP 422)" >&2
      exit 1
    fi
    parents=()
    while IFS= read -r p; do
      if ! g cat-file -e "${p}^{commit}" 2>/dev/null; then
        echo "gh: Parent SHA ${p} does not exist (HTTP 422)" >&2
        exit 1
      fi
      parents+=(-p "${p}")
    done < <(jq -r '.parents[]' "${input}")
    sha="$(jq -j '.message' "${input}" \
      | GIT_AUTHOR_NAME='fullsend-ai-coder[bot]' \
        GIT_AUTHOR_EMAIL='1+fullsend-ai-coder[bot]@users.noreply.github.com' \
        GIT_COMMITTER_NAME='GitHub' GIT_COMMITTER_EMAIL='noreply@github.com' \
        g commit-tree "$(jq -r '.tree' "${input}")" ${parents[@]+"${parents[@]}"})"
    if [ -n "${FAKE_GH_RACE:-}" ] && [ ! -e "${bare}/fake-gh-race-done" ]; then
      : > "${bare}/fake-gh-race-done"
      g update-ref "${FAKE_GH_RACE%%=*}" "${FAKE_GH_RACE#*=}"
    fi
    if [ -n "${FAKE_GH_UNVERIFIED:-}" ]; then
      jq -n --arg s "${sha}" '{sha: $s, verification: {verified: false, reason: "unsigned"}}'
    else
      jq -n --arg s "${sha}" '{sha: $s, verification: {verified: true, reason: "valid"}}'
    fi
    ;;
  "POST graphql")
    query="$(jq -r '.query' "${input}")"
    case "${query}" in
      *"repository(owner"*)
        echo '{"data":{"repository":{"id":"R_fake"}}}'
        ;;
      *updateRefs*)
        ref="$(jq -r '.variables.u[0].name' "${input}")"
        before="$(jq -r '.variables.u[0].beforeOid' "${input}")"
        after="$(jq -r '.variables.u[0].afterOid' "${input}")"
        force="$(jq -r '.variables.u[0].force' "${input}")"
        current="$(g rev-parse --verify --quiet "${ref}" || echo "${zero}")"
        if [ -n "${FAKE_GH_REF_APPLIED_502:-}" ] && [ ! -e "${FAKE_GH_REF_APPLIED_502}" ]; then
          : > "${FAKE_GH_REF_APPLIED_502}"
          g update-ref "${ref}" "${after}"
          echo "gh: Bad Gateway (HTTP 502)" >&2
          exit 1
        fi
        if [ "${current}" != "${before}" ]; then
          echo "GraphQL: Reference ${ref} is at ${current}, expected ${before} (updateRefs)" >&2
          exit 1
        fi
        if [ "${force}" != "true" ] && [ "${current}" != "${zero}" ] \
           && ! g merge-base --is-ancestor "${current}" "${after}"; then
          echo "GraphQL: Update is not a fast forward (updateRefs)" >&2
          exit 1
        fi
        g update-ref "${ref}" "${after}"
        if [ -n "${FAKE_GH_MOVE_AFTER_UPDATE:-}" ]; then
          g update-ref "${FAKE_GH_MOVE_AFTER_UPDATE%%=*}" "${FAKE_GH_MOVE_AFTER_UPDATE#*=}"
        fi
        echo '{"data":{"updateRefs":{"clientMutationId":null}}}'
        ;;
      *)
        echo "fake-gh-git-api: unsupported GraphQL query" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "fake-gh-git-api: unsupported request: ${method} ${4}" >&2
    exit 1
    ;;
esac
