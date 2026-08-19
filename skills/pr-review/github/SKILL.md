---
name: pr-review-github
description: >-
  GitHub-specific CLI commands for the PR review orchestrator. Provides
  the gh CLI and GitHub REST/GraphQL API commands used to fetch PR data,
  diffs, file contents, and issue context during review.
---

# PR Review — GitHub CLI Reference

This skill provides GitHub-specific CLI commands for the PR review
orchestrator. The orchestrator (`pr-review` skill) delegates data
fetching to these commands when `FULLSEND_FORGE=github`.

## PR data fetching

```bash
# PR metadata: title, body, author, labels, draft status, head SHA
PR_DATA=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}")
HEAD_SHA=$(echo "$PR_DATA" | jq -r '.head.sha')
IS_DRAFT=$(echo "$PR_DATA" | jq -r '.draft')

# PR files list (paginated — loop if needed)
PR_FILES=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/files?per_page=100")

# Full unified diff
gh pr diff "${PR_NUMBER}" --repo "${REPO_FULL_NAME}"

# Per-file diff (for large PRs)
git diff <merge-base>..HEAD -- <file>
```

## File contents at PR head

```bash
# Fetch file contents at a specific ref (base64-encoded)
CONTENT=$(gh api "repos/${REPO_FULL_NAME}/contents/${FILE}?ref=${HEAD_SHA}" \
  --jq '.content // empty' 2>/dev/null)
echo "$CONTENT" | base64 --decode
```

## Issue context

```bash
# Fetch linked issue metadata
gh api "repos/${REPO_FULL_NAME}/issues/<issue-number>" --jq '{title, body}'

# Fetch issue comments
gh api "repos/${REPO_FULL_NAME}/issues/<issue-number>/comments"
```

## Prior review comparison

```bash
# Compare commits between prior review and current HEAD
COMPARE=$(gh api "repos/${REPO_FULL_NAME}/compare/${PRIOR_REVIEW_SHA}...${HEAD_SHA}")
CHANGED_FILES=$(echo "$COMPARE" | jq -r '.files[].filename')
```

## Interactive mode (non-pipeline)

```bash
# Approve
gh pr review <number> --approve --body "<review comment>"

# Request changes
gh pr review <number> --request-changes --body "<review comment>"

# Comment only
gh pr review <number> --comment --body "<review comment>"
```

## GraphQL access

The review token has GraphQL read-only permissions:

```bash
gh pr view "${PR_NUMBER}" --json title,body,files,reviews
gh api graphql -f query='{ repository(owner:"OWNER", name:"REPO") {
  pullRequest(number:123) { title } } }'
```

GraphQL mutations are blocked by the sandbox proxy.
