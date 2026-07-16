#!/usr/bin/env bash
# after_each hook: capture PR state and diff created by the code agent.
#
# The code agent receives an issue fixture, but the post-script creates
# a PR on the ephemeral repo. This hook finds that PR and captures its
# state so judges can evaluate the implementation quality.
#
# Required env (forward-propagated from setup-fixture.sh):
#   EPHEMERAL_REPO  — org/name of the ephemeral repo
#   FIXTURE_NUMBER  — issue number
#
# Required env (set by harness):
#   CASE_WORKSPACE  — path to the case workspace
set -euo pipefail

CASE_WORKSPACE="${CASE_WORKSPACE:?CASE_WORKSPACE is required}"
EPHEMERAL_REPO="${EPHEMERAL_REPO:?EPHEMERAL_REPO is required}"
FIXTURE_NUMBER="${FIXTURE_NUMBER:?FIXTURE_NUMBER is required}"

OUTPUT_DIR="${CASE_WORKSPACE}/output"
mkdir -p "$OUTPUT_DIR"
PR_STATE_FILE="${OUTPUT_DIR}/pr-state.json"

# Find PRs on the ephemeral repo. The post-script creates a PR whose
# body contains "Closes #<FIXTURE_NUMBER>".
PR_JSON=$(gh pr list --repo "$EPHEMERAL_REPO" --state all \
  --json number,title,state,body,headRefName,baseRefName,additions,deletions,changedFiles,labels \
  --jq '.[0]' 2>/dev/null || echo "null")

if [ -z "$PR_JSON" ] || [ "$PR_JSON" = "null" ]; then
  jq -n '{error: "No PR found on ephemeral repo"}' > "$PR_STATE_FILE"
  echo "No PR found — writing empty state"
  exit 0
fi

PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')

# Capture the diff for the code quality judge.
PR_DIFF=$(gh pr diff "$PR_NUMBER" --repo "$EPHEMERAL_REPO" 2>/dev/null || echo "")

# Build the output.
jq -n \
  --argjson pr "$PR_JSON" \
  --arg diff "$PR_DIFF" \
  '{
    number: $pr.number,
    title: $pr.title,
    state: $pr.state,
    body: $pr.body,
    head_branch: $pr.headRefName,
    base_branch: $pr.baseRefName,
    additions: $pr.additions,
    deletions: $pr.deletions,
    changed_files: $pr.changedFiles,
    labels: [($pr.labels // [])[] | .name],
    diff: $diff
  }' > "$PR_STATE_FILE"

echo "Captured PR #${PR_NUMBER} state -> ${PR_STATE_FILE}"
