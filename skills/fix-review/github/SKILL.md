---
name: fix-review-github
description: >-
  GitHub CLI commands for fetching PR metadata and diffs in the fix agent.
  Use gh to view PR state, diff, and comments.
---

# Fix Review — GitHub CLI

Use the `gh` CLI to fetch PR data for the fix agent. The environment
provides `GH_TOKEN` for authentication.

## PR Metadata

```bash
# View PR with full details
gh pr view "${PR_NUMBER}" --json number,title,body,headRefName,baseRefName,state,files,labels

# View PR state only
gh pr view "${PR_NUMBER}" --json state --jq '.state'
```

## PR Diff

```bash
# Fetch the current diff
gh pr diff "${PR_NUMBER}"
```

## PR Comments

```bash
# List review comments (for context on prior iterations)
gh api repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/reviews --jq '.[].body'
```
