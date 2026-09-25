---
name: github
description: >-
  Use when interacting with GitHub repositories, issues, or pull requests via
  the gh CLI. Shared by all agents running on the GitHub forge.
---

# GitHub CLI

Use the `gh` CLI to interact with GitHub repositories. The environment
provides `GH_TOKEN` for authentication.

## Issues

```bash
# View an issue with full details
gh issue view NUMBER --repo OWNER/REPO --json number,title,body,labels,assignees,createdAt,updatedAt,author,comments,state,milestone

# List open issues
gh issue list --repo OWNER/REPO --state open --json number,title,body --limit 100

# Search issues by keyword
gh issue list --repo OWNER/REPO --state open --search "keyword" --json number,title,body --limit 30

# Include closed issues when verifying finished children of a tracking issue
gh issue list --repo OWNER/REPO --state all --json number,title,state --limit 100

# List GitHub native sub-issues (child issues), including closed ones
gh api graphql -F owner="OWNER" -F name="REPO" -F number:=ISSUE_NUMBER -f query='
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) {
        subIssues(first: 50) {
          nodes { number title state url }
        }
      }
    }
  }' --jq '.data.repository.issue.subIssues.nodes'
```

## Re-check Data

Comment authors with their account type, creation time and fullsend
marker, for the end-of-run re-check. `--paginate` is required: an active issue exceeds one
page.

```bash
# Through a file: gh's --jq takes one expression and has no --arg.
gh api --paginate "repos/OWNER/REPO/issues/NUMBER/comments" > /tmp/recheck-comments.json
jq -c --arg since "$FULLSEND_RUN_STARTED_AT" '.[] | select((.created_at | fromdate) > ($since | fromdate))
  | {login: .user.login, type: .user.type, at: .created_at, fullsend: ((.body // "") | contains("<!-- fullsend:")), body}' /tmp/recheck-comments.json
```

`fullsend` marks a body carrying the marker; it excludes the item only when
`type` is `"Bot"` — a human's comment is never excluded, marker or not.
Fullsend's exact logins are `fullsend-ai-${FULLSEND_ROLE}[bot]` and any App
login that authored a marked comment on this issue, never a pattern; `type`
tells an App from a human, never the login's shape, and other Apps stay in
as context. The `since` filter parses both timestamps, as the other forges do.

## Pull Requests

```bash
# List open PRs
gh pr list --repo OWNER/REPO --state open --json number,title,body,isDraft --limit 50

# Search PRs by keyword
gh pr list --repo OWNER/REPO --state open --search "keyword" --json number,url,title,body,isDraft,author --limit 30

# Find PRs linked to an issue via closing keywords (Fixes, Closes, etc.)
gh api graphql -F owner="OWNER" -F name="REPO" -F number:=ISSUE_NUMBER -f query='
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) {
        closedByPullRequestsReferences(first: 50) {
          nodes { number url author { login } state }
        }
      }
    }
  }' --jq '.data.repository.issue.closedByPullRequestsReferences.nodes'

# View a specific PR
gh pr view NUMBER --repo OWNER/REPO --json state,title,body,comments,labels,mergedAt
```

## Repository Contents

```bash
# List root directory files
gh api repos/OWNER/REPO/contents/ --jq '.[].name'

# Read a specific file
gh api repos/OWNER/REPO/contents/PATH --jq '.content' | base64 -d
```

## Cross-Repo Searches

```bash
# Search issues in another repo
gh issue list --repo OTHER-ORG/OTHER-REPO --state open --search "relevant keywords" --json number,title,body --limit 30

# Search PRs in another repo
gh pr list --repo OTHER-ORG/OTHER-REPO --state open --search "relevant keywords" --json number,title,body --limit 30
```

Extract OWNER/REPO from the issue URL:
```bash
REPO=$(echo "${ISSUE_URL}" | sed 's|https://github.com/||; s|/issues/.*||')
ISSUE_NUMBER=$(basename "${ISSUE_URL}")
```
