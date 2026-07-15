#!/usr/bin/env bash
# after_each hook: capture fixture state for judges.
#
# Snapshots the GitHub issue/PR state into output/fixture-state.json
# so judges can evaluate the agent's work.
#
# Required env (forward-propagated from setup-fixture.sh):
#   EPHEMERAL_REPO  — org/name of the ephemeral repo
#   FIXTURE_NUMBER  — issue or PR number
#   FIXTURE_TYPE    — "issue" or "pull_request"
#   FIXTURE_URL     — full URL of the fixture
#   FORGE           — "github"
#
# Required env (set by harness):
#   CASE_WORKSPACE  — path to the case workspace
set -euo pipefail

CASE_WORKSPACE="${CASE_WORKSPACE:?CASE_WORKSPACE is required}"
EPHEMERAL_REPO="${EPHEMERAL_REPO:?EPHEMERAL_REPO is required}"
FIXTURE_NUMBER="${FIXTURE_NUMBER:?FIXTURE_NUMBER is required}"
FIXTURE_TYPE="${FIXTURE_TYPE:?FIXTURE_TYPE is required}"
FIXTURE_URL="${FIXTURE_URL:?FIXTURE_URL is required}"

OUTPUT_DIR="${CASE_WORKSPACE}/output"
mkdir -p "$OUTPUT_DIR"
STATE_FILE="${OUTPUT_DIR}/fixture-state.json"

# Run a command up to 3 times; print stdout on success. Used for flaky gh calls.
retry_cmd() {
  local attempt out
  for attempt in 1 2 3; do
    if out=$("$@" 2>/dev/null); then
      printf '%s' "$out"
      return 0
    fi
    # Skip sleep after the final attempt.
    [[ $attempt -lt 3 ]] && sleep $((attempt))
  done
  return 1
}

# Best-effort gh pr view for changed file paths. On persistent failure returns
# non-zero so callers can record files_fetch_failed instead of a silent [].
fetch_pr_files() {
  local num="$1"
  local files
  if files=$(retry_cmd gh pr view "$num" --repo "$EPHEMERAL_REPO" --json files \
    --jq '[(.files // [])[].path]'); then
    printf '%s' "$files"
    return 0
  fi
  return 1
}

case "${FIXTURE_TYPE}" in
  issue)
    issue_json=$(gh issue view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
      --json state,labels,assignees,milestone,title)
    comments_json=$(gh issue view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json comments \
      | jq '[.comments[] | {author: .author.login, body: .body, created_at: .createdAt}]')
    # Code agent post-script opens exactly one PR today; --limit 1 is enough.
    # Raise the limit (or filter by headRefName) if a future case opens multiple.
    # gh pr list is best-effort so a transient API blip still yields fixture-state.json.
    if ! prs_json=$(gh pr list --repo "$EPHEMERAL_REPO" --state all --limit 1 \
      --json number,title,url,state,headRefName,baseRefName 2>/dev/null); then
      echo "WARNING: gh pr list failed for ${EPHEMERAL_REPO}; recording pull_requests=[]" >&2
      prs_json='[]'
    fi
    if [[ -z "$prs_json" ]]; then
      prs_json='[]'
    fi

    pr_lines=()
    while IFS= read -r pr; do
      [[ -z "$pr" ]] && continue
      num=$(echo "$pr" | jq -r '.number')
      if files=$(fetch_pr_files "$num"); then
        pr_lines+=("$(echo "$pr" | jq -c --argjson files "$files" \
          '. + {head: .headRefName, base: .baseRefName, files: $files, files_fetch_failed: false}
           | del(.headRefName, .baseRefName)')")
      else
        echo "WARNING: gh pr view failed for PR #${num}; marking files_fetch_failed" >&2
        pr_lines+=("$(echo "$pr" | jq -c \
          '. + {head: .headRefName, base: .baseRefName, files: null, files_fetch_failed: true}
           | del(.headRefName, .baseRefName)')")
      fi
    done < <(echo "$prs_json" | jq -c '.[]')
    if [[ ${#pr_lines[@]} -eq 0 ]]; then
      prs_with_files='[]'
    else
      prs_with_files=$(printf '%s\n' "${pr_lines[@]}" | jq -s '.')
    fi

    jq -n \
      --arg fixture_type "issue" \
      --arg fixture_url "$FIXTURE_URL" \
      --argjson issue "$issue_json" \
      --argjson comments "$comments_json" \
      --argjson pull_requests "$prs_with_files" \
      '{
        fixture_type: $fixture_type,
        fixture_url: $fixture_url,
        state: $issue.state,
        title: $issue.title,
        labels: [($issue.labels // [])[] | .name],
        assignees: [($issue.assignees // [])[] | .login],
        milestone: ($issue.milestone.title // null),
        comments: $comments,
        pull_requests: $pull_requests
      }' > "$STATE_FILE"
    ;;

  pull_request)
    # One retried gh call for metadata + comments + reviews + files, then shape
    # with jq. On persistent failure still write fixture-state.json so judges
    # fail clearly instead of the after_each hook aborting.
    pre_agent_head="${PRE_AGENT_HEAD:-}"
    if [[ -z "$pre_agent_head" && -f "${OUTPUT_DIR}/pre-agent-head.txt" ]]; then
      pre_agent_head=$(cat "${OUTPUT_DIR}/pre-agent-head.txt")
    fi

    if ! pr_raw=$(retry_cmd gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
      --json state,labels,assignees,milestone,title,mergeable,reviewDecision,headRefOid,headRefName,comments,reviews,files); then
      echo "WARNING: gh pr view failed for PR #${FIXTURE_NUMBER} after retries; writing pr_fetch_failed state" >&2
      jq -n \
        --arg fixture_type "pull_request" \
        --arg fixture_url "$FIXTURE_URL" \
        --arg pre_agent_head "$pre_agent_head" \
        '{
          fixture_type: $fixture_type,
          fixture_url: $fixture_url,
          pr_fetch_failed: true,
          state: null,
          title: null,
          labels: [],
          assignees: [],
          milestone: null,
          mergeable: null,
          review_decision: null,
          comments: [],
          reviews: [],
          head_sha: null,
          head_ref: null,
          files: null,
          files_fetch_failed: true,
          pre_agent_head: (if $pre_agent_head == "" then null else $pre_agent_head end)
        }' > "$STATE_FILE"
      echo "Captured ${FIXTURE_TYPE} state -> ${STATE_FILE}"
      exit 0
    fi

    # Prefer the branch tip from the git refs API: PR headRefOid can lag briefly
    # after post-fix pushes, which falsely fails the new_commit judge.
    head_ref=$(printf '%s' "$pr_raw" | jq -r '.headRefName // empty')
    head_sha=$(printf '%s' "$pr_raw" | jq -r '.headRefOid // empty')
    if [[ -n "$head_ref" ]]; then
      if ref_sha=$(gh api "repos/${EPHEMERAL_REPO}/git/ref/heads/${head_ref}" \
        --jq '.object.sha' 2>/dev/null); then
        head_sha="$ref_sha"
      fi
      # If still equal to pre-agent baseline, poll briefly for the push to show up.
      if [[ -n "$pre_agent_head" && "$head_sha" == "$pre_agent_head" ]]; then
        echo "WARNING: PR/branch tip still equals pre_agent_head; polling for push..." >&2
        for attempt in 1 2 3 4 5 6; do
          sleep $((attempt))
          if ref_sha=$(gh api "repos/${EPHEMERAL_REPO}/git/ref/heads/${head_ref}" \
            --jq '.object.sha' 2>/dev/null); then
            head_sha="$ref_sha"
            if [[ "$head_sha" != "$pre_agent_head" ]]; then
              break
            fi
          fi
        done
      fi
    fi

    jq -n \
      --arg fixture_type "pull_request" \
      --arg fixture_url "$FIXTURE_URL" \
      --argjson pr "$pr_raw" \
      --arg head_sha "$head_sha" \
      --arg pre_agent_head "$pre_agent_head" \
      '{
        fixture_type: $fixture_type,
        fixture_url: $fixture_url,
        pr_fetch_failed: false,
        state: $pr.state,
        title: $pr.title,
        labels: [($pr.labels // [])[] | .name],
        assignees: [($pr.assignees // [])[] | .login],
        milestone: ($pr.milestone.title // null),
        mergeable: $pr.mergeable,
        review_decision: $pr.reviewDecision,
        comments: [($pr.comments // [])[] | {author: .author.login, body: .body, created_at: .createdAt}],
        reviews: [($pr.reviews // [])[] | {author: .author.login, state: .state, body: .body}],
        head_sha: (if $head_sha == "" then $pr.headRefOid else $head_sha end),
        head_ref: $pr.headRefName,
        files: [($pr.files // [])[] | .path],
        files_fetch_failed: false,
        pre_agent_head: (if $pre_agent_head == "" then null else $pre_agent_head end)
      }' > "$STATE_FILE"
    ;;

  *)
    echo "ERROR: unsupported fixture_type: ${FIXTURE_TYPE}" >&2
    exit 1
    ;;
esac

echo "Captured ${FIXTURE_TYPE} state -> ${STATE_FILE}"
