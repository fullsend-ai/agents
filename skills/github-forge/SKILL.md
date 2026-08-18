---
name: github
description: >-
  GitHub CLI commands for interacting with repositories, issues, and pull
  requests via the gh CLI. Shared by all agents running on the GitHub forge.
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

# Search PRs by keyword or issue number
gh pr list --repo OWNER/REPO --state open --search "ISSUE_NUMBER in:body,title" --json number,url,title,body,isDraft,author --limit 30

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
