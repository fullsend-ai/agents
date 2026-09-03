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

## Re-check Data

The final re-check needs the current head and the activity created after the
run started, with the author and time of each. `--paginate` is required: an
active PR exceeds one page.

```bash
# Current head SHA
gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}" --jq '.head.sha'

# General PR comments
gh api --paginate "repos/${REPO_FULL_NAME}/issues/${PR_NUMBER}/comments" \
  --jq '.[] | {login: .user.login, type: .user.type, at: .created_at, body}'

# Reviews — note the field is submitted_at, not created_at
gh api --paginate "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/reviews" \
  --jq '.[] | {login: .user.login, type: .user.type, at: .submitted_at, body}'

# Inline review comments
gh api --paginate "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/comments" \
  --jq '.[] | {login: .user.login, type: .user.type, at: .created_at, body}'
```

`.user.type` is `"Bot"` for app-authored activity — a more reliable bot test
than the `[bot]` login suffix, which a human account may also carry. These
timestamps are RFC 3339 UTC with no fractional seconds, in the same format as
`FULLSEND_RUN_STARTED_AT`, so a string comparison against it orders correctly.
