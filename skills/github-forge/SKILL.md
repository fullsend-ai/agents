---
name: github-forge
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
```

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
