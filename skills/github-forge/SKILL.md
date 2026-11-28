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

# Issue comments with body, author type, App, and creation and edit times.
# gh issue view drops the "[bot]" suffix from App logins, gives no edit
# time, and uses different comment ids, so read the comments from this
# listing whenever a comment's author or timing matters.
# performed_via_github_app.slug is null for a comment no App posted.
gh api --paginate repos/OWNER/REPO/issues/NUMBER/comments \
  --jq '.[] | {id, user: {login: .user.login, type: .user.type}, performed_via_github_app: {slug: .performed_via_github_app.slug}, created_at, updated_at, body}'

# Who last edited each comment, and when (the listing above does not say).
# databaseId is the id in that listing; logins here have no "[bot]"
# suffix (fullsend-ai/agents#2042: the status comment fullsend edited
# reports editor {__typename: "Bot", login: "fullsend-ai-triage"}), so
# check that editor.__typename is Bot. Add -f after=<endCursor> while
# hasNextPage is true.
gh api graphql -F owner=OWNER -F name=REPO -F number=NUMBER -f query='
  query($owner: String!, $name: String!, $number: Int!, $after: String) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) {
        comments(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { databaseId createdAt lastEditedAt editor { __typename login } }
        }
      }
    }
  }' --jq '.data.repository.issue.comments'

# List open issues
gh issue list --repo OWNER/REPO --state open --json number,title,body --limit 100

# Search issues by keyword
gh issue list --repo OWNER/REPO --state open --search "keyword" --json number,title,body --limit 30

# Include closed issues when verifying finished children of a tracking issue
# (closed issues are context only — never a duplicate target)
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

## Parent Issue

A GitHub sub-issue has at most one parent issue, which can be in another
repository. This query returns the parent's title, body, and state. Empty
output means the issue has no parent. Treat a non-zero exit or a GraphQL
error as a failed read.

```bash
gh api graphql -F owner="OWNER" -F name="REPO" -F number=ISSUE_NUMBER -f query='
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) {
        parent { number title body state url repository { nameWithOwner } }
      }
    }
  }' --jq '.data.repository.issue.parent'
```

To read the next ancestor, run the query again with the parent's `number` and
with OWNER and REPO taken from its `repository.nameWithOwner`.

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
REPO=$(printf '%s\n' "$ISSUE_URL" | sed 's|https://github.com/||; s|/issues/.*||')
ISSUE_NUMBER="${ISSUE_URL##*/}"
```
