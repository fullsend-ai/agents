# shellcheck shell=bash

# enforce_branch_namespace <branch> <issue_number>
# Prints the deterministic safe branch name on stdout.
enforce_branch_namespace() {
  local branch="$1"
  local issue_number="$2"

  local slug="${branch##*/}"
  slug="${slug#"${issue_number}-"}"
  slug="$(printf '%s' "${slug}" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -cs 'a-z0-9-' '-')"
  if [ "${#slug}" -gt 60 ]; then
    local hash
    hash="$(printf '%s' "${slug}" | sha1sum | head -c 8)"
    slug="$(printf '%s' "${slug}" | head -c 51)-${hash}"
  fi
  slug="$(printf '%s' "${slug}" | sed 's/^-*//;s/-*$//')"
  if [ -z "${slug}" ]; then
    slug="impl"
  fi
  echo "agent/${issue_number}-${slug}"
}

# pr_body_refs_issue <pr_body> <issue_number>
# Returns 0 if the PR body references the issue, non-zero otherwise.
pr_body_refs_issue() {
  local pr_body="$1"
  local issue_number="$2"

  printf '%s' "${pr_body}" | tr -d '\r' \
    | grep -qiE "(Close[sd]?|Fix(e[sd])?|Resolve[sd]?|Related to)[[:space:]]+#${issue_number}([^0-9]|$)"
}

# classify_branch_vs_pr_head <branch> <expected_branch>
# Prints one of: "skip", "match", or "mismatch".
classify_branch_vs_pr_head() {
  local branch="$1"
  local expected_branch="$2"

  if [ -z "${expected_branch}" ]; then
    echo "skip"
  elif [ "${branch}" = "${expected_branch}" ]; then
    echo "match"
  else
    echo "mismatch"
  fi
}
