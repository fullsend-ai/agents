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

case "${FIXTURE_TYPE}" in
  issue)
    issue_json=$(gh issue view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
      --json state,labels,assignees,milestone,title)
    comments_json=$(gh issue view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json comments \
      | jq '[.comments[] | {author: .author.login, body: .body, created_at: .createdAt}]')

    jq -n \
      --arg fixture_type "issue" \
      --arg fixture_url "$FIXTURE_URL" \
      --argjson issue "$issue_json" \
      --argjson comments "$comments_json" \
      '{
        fixture_type: $fixture_type,
        fixture_url: $fixture_url,
        state: $issue.state,
        title: $issue.title,
        labels: [($issue.labels // [])[] | .name],
        assignees: [($issue.assignees // [])[] | .login],
        milestone: ($issue.milestone.title // null),
        comments: $comments
      }' > "$STATE_FILE"
    ;;

  pull_request)
    pr_json=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
      --json state,labels,assignees,milestone,title,mergeable,reviewDecision,headRefOid,headRefName)
    comments_json=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json comments \
      | jq '[.comments[] | {author: .author.login, body: .body, created_at: .createdAt}]')
    reviews_json=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json reviews \
      | jq '[.reviews[] | {author: .author.login, state: .state, body: .body}]')

    files='[]'
    files_fetch_failed=false
    if files_json=$(fetch_pr_files "$FIXTURE_NUMBER"); then
      files="$files_json"
    else
      echo "WARNING: gh pr view failed for PR #${FIXTURE_NUMBER}; marking files_fetch_failed" >&2
      files='null'
      files_fetch_failed=true
    fi

    # Optional: runner exported PRE_AGENT_HEAD into the hook env via forward-propagation
    # if we write it to .hook-outputs — for v1 read from process env if present.
    pre_agent_head="${PRE_AGENT_HEAD:-}"

    jq -n \
      --arg fixture_type "pull_request" \
      --arg fixture_url "$FIXTURE_URL" \
      --argjson pr "$pr_json" \
      --argjson comments "$comments_json" \
      --argjson reviews "$reviews_json" \
      --argjson files "$files" \
      --argjson files_fetch_failed "$files_fetch_failed" \
      --arg pre_agent_head "$pre_agent_head" \
      '{
        fixture_type: $fixture_type,
        fixture_url: $fixture_url,
        state: $pr.state,
        title: $pr.title,
        labels: [($pr.labels // [])[] | .name],
        assignees: [($pr.assignees // [])[] | .login],
        milestone: ($pr.milestone.title // null),
        mergeable: $pr.mergeable,
        review_decision: $pr.reviewDecision,
        comments: $comments,
        reviews: $reviews,
        head_sha: $pr.headRefOid,
        head_ref: $pr.headRefName,
        files: $files,
        files_fetch_failed: $files_fetch_failed,
        pre_agent_head: (if $pre_agent_head == "" then null else $pre_agent_head end)
      }' > "$STATE_FILE"
    ;;

  *)
    echo "ERROR: unsupported fixture_type: ${FIXTURE_TYPE}" >&2
    exit 1
    ;;
esac

echo "Captured ${FIXTURE_TYPE} state -> ${STATE_FILE}"
