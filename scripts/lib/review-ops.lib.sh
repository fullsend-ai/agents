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

# Classify one finding id against normalized threads (see the forge libs).
# Input: {complete, head_sha, threads}. Args: $id, $head (the commit this
# review evaluated), $marker (the reply idempotency marker). Output:
# {status, thread_id, url, replied}. Only "ready" may be acted on.
#
# The thread must be the single unresolved thread whose first comment is a
# review-bot comment carrying exactly this id's stamp and no other. A stamp
# in a human reply never makes a thread the finding's thread.
_FINDING_THREAD_CLASSIFY='
  def stamps: [ scan("<!--[[:space:]]+finding:(f_[A-Za-z0-9]+)[[:space:]]+-->") | .[0] ] | unique;
  (.head_sha // "") as $live
  | [ (.threads // [])[] | select(any(.comments[]?; .body | stamps | index($id) != null)) ] as $cand
  | [ $cand[] | select((.comments[0].review_bot // false) and ((.comments[0].body // "") | stamps) == [$id]) ] as $owned
  | [ $owned[] | select(.resolved | not) ] as $open
  | if (.complete | not) then {status: "incomplete", thread: (if ($owned | length) == 1 then $owned[0] else null end)}
    elif ($cand | length) == 0 then {status: "missing", thread: null}
    elif ($owned | length) == 0 then {status: "human-owned", thread: $cand[0]}
    elif ($open | length) == 0 then {status: "already-resolved", thread: $owned[0]}
    elif ($open | length) > 1 then {status: "ambiguous", thread: $open[0]}
    else $open[0] as $t
      | if ($t.comments_complete | not) then {status: "incomplete", thread: $t}
        elif $head == "" or ($live | ascii_downcase) != ($head | ascii_downcase) then {status: "changed-head", thread: $t}
        elif any($t.comments[]; (.review_bot or .own) | not) then {status: "other-comment", thread: $t}
        elif ($t.can_resolve | not) then {status: "not-resolvable", thread: $t}
        else {status: "ready", thread: $t}
        end
    end
  | {
      status,
      thread_id: (.thread.id // null),
      url: (.thread.url // ""),
      replied: (.thread != null and any(.thread.comments[]?; .own and (.body | contains($marker))))
    }
'

# Resolve the review threads of prior findings this review settled.
#
# $1 — JSON array of {id, rationale, evidence}: prior ids whose effective
#      ledger status is resolved_by_change (rationale and evidence given, and
#      the id not reported again).
# $2 — the head SHA the review evaluated.
#
# Each id must map to one exact, review-bot-stamped, unresolved thread (see
# _FINDING_THREAD_CLASSIFY). The thread is re-read just before acting and
# left open when the PR head moved, anyone but the review bot commented in
# it (a person, or another bot such as the fix agent), or it cannot be read
# completely or resolved. An explanation is posted first, led by a marker
# so a rerun at the same head never posts it twice; when the explanation
# cannot be posted the thread stays open. A thread a concurrent run already
# resolved counts as done.
#
# Prints a JSON array of {id, status, url}. Forge errors are reported per
# thread and never fail the caller.
forge_reconcile_finding_threads() {
  local settled="$1" head="$2"
  local entries listing item id rationale evidence marker verdict status url thread_id fresh body

  entries='[]'
  _finding_thread_entry() {
    entries=$(jq -c --arg id "$1" --arg status "$2" --arg url "${3:-}" --arg pr_url "${PR_URL}" \
      '. + [{id: $id, status: $status, url: (if $url == "" then $pr_url else $url end)}]' <<< "${entries}")
  }

  if ! listing="$(forge_fetch_finding_threads)" \
      || ! jq -e 'type == "object" and (.threads | type) == "array"' <<< "${listing}" >/dev/null 2>&1; then
    echo "::warning::Could not read review threads — threads of resolved findings left open" >&2
    listing=""
  fi

  while IFS= read -r item; do
    [[ -z "${item}" ]] && continue
    id="$(jq -r '.id' <<< "${item}")"
    rationale="$(jq -r '.rationale' <<< "${item}")"
    evidence="$(jq -r '.evidence' <<< "${item}")"
    if [[ -z "${listing}" ]]; then
      _finding_thread_entry "${id}" "fetch-failed"
      continue
    fi
    marker="<!-- fullsend:review-resolve finding=${id} head=${head} -->"

    verdict="$(jq -c --arg id "${id}" --arg head "${head}" --arg marker "${marker}" \
      "${_FINDING_THREAD_CLASSIFY}" <<< "${listing}")"
    status="$(jq -r '.status' <<< "${verdict}")"
    url="$(jq -r '.url' <<< "${verdict}")"
    thread_id="$(jq -r '.thread_id // empty' <<< "${verdict}")"
    if [[ "${status}" != "ready" ]]; then
      _finding_thread_entry "${id}" "${status}" "${url}"
      continue
    fi

    # Re-read the thread's current state immediately before acting on it.
    if ! fresh="$(forge_fetch_finding_thread "${thread_id}")" \
        || ! jq -e 'type == "object" and has("thread")' <<< "${fresh}" >/dev/null 2>&1; then
      echo "::warning::Could not re-read the review thread of a resolved finding — left open" >&2
      _finding_thread_entry "${id}" "fetch-failed" "${url}"
      continue
    fi
    verdict="$(jq -c --arg id "${id}" --arg head "${head}" --arg marker "${marker}" \
      '{complete: true, head_sha: .head_sha, threads: ([.thread] | map(select(. != null)))} | '"${_FINDING_THREAD_CLASSIFY}" \
      <<< "${fresh}")"
    status="$(jq -r '.status' <<< "${verdict}")"
    if [[ "${status}" != "ready" ]]; then
      _finding_thread_entry "${id}" "${status}" "${url}"
      continue
    fi

    if [[ "$(jq -r '.replied' <<< "${verdict}")" != "true" ]]; then
      body="$(jq -rn --arg marker "${marker}" --arg id "${id}" --arg sha "${head:0:12}" \
        --arg rationale "${rationale}" --arg evidence "${evidence}" '
        # Untrusted model text: no HTML comments (a stamp or marker could be
        # forged), no finding ids, bounded length.
        def clean:
          gsub("\r\n?"; "\n") | gsub("<!--"; "&lt;!--")
          | gsub("\\b" + $id + "\\b"; "") | gsub("\\bf_[0-9a-f]{16}\\b"; "")
          | .[0:1500];
        $marker + "\n"
        + "**Resolved by the review agent:** a later review found this finding fixed at commit " + $sha + ".\n\n"
        + "**Why:** " + ($rationale | clean) + "\n\n"
        + "**Evidence:** " + ($evidence | clean) + "\n\n"
        + "_Resolving this thread. Unresolve it if you disagree._"')"
      if ! forge_reply_finding_thread "${thread_id}" "${body}"; then
        if fresh="$(forge_fetch_finding_thread "${thread_id}")" \
            && jq -e '.thread.resolved == true' <<< "${fresh}" >/dev/null 2>&1; then
          _finding_thread_entry "${id}" "already-resolved" "${url}"
        else
          echo "::warning::Could not post the explanation in the review thread of a resolved finding — left open" >&2
          _finding_thread_entry "${id}" "reply-failed" "${url}"
        fi
        continue
      fi
    fi

    if forge_resolve_finding_thread "${thread_id}"; then
      _finding_thread_entry "${id}" "resolved" "${url}"
    elif fresh="$(forge_fetch_finding_thread "${thread_id}")" \
        && jq -e '.thread.resolved == true' <<< "${fresh}" >/dev/null 2>&1; then
      _finding_thread_entry "${id}" "resolved" "${url}"
    else
      echo "::warning::Could not resolve the review thread of a resolved finding" >&2
      _finding_thread_entry "${id}" "resolve-failed" "${url}"
    fi
  done < <(jq -c '.[]?' <<< "${settled}")

  printf '%s\n' "${entries}"
}
