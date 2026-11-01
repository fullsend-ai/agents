#!/usr/bin/env bash
# shellcheck shell=bash
# review-ops.lib.sh — Forge-dispatch wrapper for review operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${REVIEW_OPS_SH_LOADED:-}" ]] && return 0
REVIEW_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

case "${FULLSEND_FORGE:-}" in
  github)
    source "${SCRIPT_DIR}/lib/github-review-ops.lib.sh"
    ;;
  gitlab)
    source "${SCRIPT_DIR}/lib/gitlab-review-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac

# Fetch resolved review threads once per stage and return rich, verified
# records for both pre-review ledger updates and post-review result checks.
# Comment bodies never leave the host: only authors and exact finding-ID
# stamps are retained in the returned records.
forge_get_human_dismissals() {
  local pr_author response trusted_reviewers
  local -a fetch_args

  pr_author="$(forge_get_pr_author)"
  if [[ -z "${pr_author}" ]]; then
    echo "::warning::Could not determine the PR author — human dismissals cannot be verified" >&2
    echo '[]'
    return 0
  fi

  case "${FULLSEND_FORGE}" in
    github)
      local org app_set
      org="${REPO%%/*}"
      app_set="${FULLSEND_APP_SET:-}"
      trusted_reviewers="$(jq -nc \
        --arg org "${org}" \
        --arg app_set "${app_set}" '
          [
            ($org + "-review"), ($org + "-review[bot]"),
            "fullsend-ai-review", "fullsend-ai-review[bot]",
            (if $app_set == "" then empty else ($app_set + "-review"), ($app_set + "-review[bot]") end)
          ] | unique
        ')"
      ;;
    gitlab)
      local review_actor
      review_actor="$(_gitlab_api GET "/user" 2>/dev/null | jq -r '.username // empty' 2>/dev/null)" || review_actor=""
      if [[ -z "${review_actor}" ]]; then
        echo "::warning::Could not determine the GitLab review bot — human dismissals cannot be verified" >&2
        echo '[]'
        return 0
      fi
      trusted_reviewers="$(jq -nc --arg actor "${review_actor}" '[$actor]')"
      ;;
  esac

  fetch_args=(fetch-review-threads --forge "${FULLSEND_FORGE}" --repo "${REPO}" --pr "${PR_NUMBER}")
  if [[ "${FULLSEND_FORGE}" == "gitlab" && -n "${CI_SERVER_URL:-}" ]]; then
    fetch_args+=(--base-url "${CI_SERVER_URL}")
  fi
  if ! response="$(GH_TOKEN="${REVIEW_TOKEN:-${GH_TOKEN:-}}" \
    GITLAB_TOKEN="${REVIEW_TOKEN:-${GITLAB_TOKEN:-}}" \
    fullsend "${fetch_args[@]}" 2>/dev/null)"; then
    echo "::warning::Failed to fetch review threads — human dismissals cannot be verified" >&2
    echo '[]'
    return 0
  fi

  if ! jq -e 'type == "object" and (.threads | type == "array") and (.truncated == false)' \
    <<< "${response}" >/dev/null 2>&1; then
    echo "::warning::Review thread fetch was invalid or truncated — human dismissals cannot be verified" >&2
    echo '[]'
    return 0
  fi

  jq -c --arg author "${pr_author}" --arg forge "${FULLSEND_FORGE}" --argjson trusted "${trusted_reviewers}" '
    [ .threads[]
      | select(type == "object")
      | select(.is_resolved == true)
      | select(.resolved_by_type == "User")
      | select(.resolved_by_role_verified == true)
      | select(.resolved_by_role | IN("write", "maintain", "admin"))
      | select((.resolved_by | ascii_downcase) != ($author | ascii_downcase))
      | select(.comments_truncated == false)
      | . as $thread
      | [ $thread.comments[]?
          | {
              author: (.author // ""),
              author_type: (.author_type // ""),
              finding_ids: [(.body // "" | scan("<!--[[:space:]]+finding:(f_[A-Za-z0-9]+)[[:space:]]+-->") | .[0])] | unique
            }
        ] as $comments
      | [ $comments[]
          | select(
              if $forge == "github" then
                (.author_type == "Bot") and
                (.author as $login | ($trusted | map(ascii_downcase) | index($login | ascii_downcase)) != null)
              else
                (.author as $login | ($trusted | map(ascii_downcase) | index($login | ascii_downcase)) != null)
              end
            )
        ] as $trusted_comments
      | select(($trusted_comments | length) > 0)
      | {
          path: $thread.path,
          line: $thread.line,
          resolved_by: $thread.resolved_by,
          resolved_by_type: $thread.resolved_by_type,
          resolved_by_role: $thread.resolved_by_role,
          resolved_by_role_verified: $thread.resolved_by_role_verified,
          comment_authors: ($comments | map({author, author_type})),
          finding_ids: ([$trusted_comments[].finding_ids[]] | unique)
        }
    ]
  ' <<< "${response}" 2>/dev/null || echo '[]'
}
