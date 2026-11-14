#!/usr/bin/env bash
# authorized-range.sh BASE_REF — prints the redo/reset range for the fix agent:
#   REWRITE_BASE=<sha>   parent of the oldest in-scope commit
#   IN_SCOPE=<n>         number of contiguous fix-agent commits at HEAD
# Exits 1 with the reason when HEAD is not the fix agent's, so the caller
# fails closed. A commit is the fix agent's by the identity rule under
# "Fail closed" in SKILL.md, the rule post-fix applies as
# commit_author_identity.
set -euo pipefail
base_ref="${1:?usage: authorized-range.sh BASE_REF}"
: "${GIT_AUTHOR_NAME:?}" "${GIT_AUTHOR_EMAIL:?}"
me="${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>"

author_of() {
  local sha="$1" name email trailers
  IFS=$'\t' read -r name email <<< "$(git log -1 --format='%an%x09%ae' "${sha}")"
  if [[ "${name}" == *"[bot]" && "${email}" == "${GIT_AUTHOR_EMAIL}" ]]; then
    trailers="$(git log -1 --format='%(trailers:key=Authored-by,valueonly)' "${sha}" | sed '/^$/d')"
    if [ -n "${trailers}" ] && [ "$(printf '%s\n' "${trailers}" | wc -l | tr -d ' ')" = "1" ]; then
      printf '%s\n' "${trailers}"
      return
    fi
  fi
  printf '%s <%s>\n' "${name}" "${email}"
}

merge_base="$(git merge-base HEAD "${base_ref}")" || { echo "no merge base with ${base_ref}" >&2; exit 1; }
n=0
oldest=""
for sha in $(git rev-list --first-parent "${merge_base}..HEAD"); do
  [ "$(author_of "${sha}")" = "${me}" ] || break
  n=$((n + 1))
  oldest="${sha}"
done
if [ "${n}" -eq 0 ]; then
  echo "HEAD is not authored by ${me}; nothing to rewrite" >&2
  exit 1
fi
echo "REWRITE_BASE=$(git rev-parse "${oldest}^")"
echo "IN_SCOPE=${n}"
