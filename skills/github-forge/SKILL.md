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

## Pull Requests

```bash
# List open PRs
gh pr list --repo OWNER/REPO --state open --json number,title,body,isDraft --limit 50

# Search PRs by keyword
gh pr list --repo OWNER/REPO --state open --search "keyword" --json number,url,title,body,isDraft,author --limit 30

# Find PRs linked to an issue via closing keywords (Fixes, Closes, etc.).
# Includes PRs in other repositories that use Closes OWNER/REPO#N.
# Inspect each node's state: OPEN = in-flight, MERGED = completed,
# CLOSED = abandoned (not in-flight).
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

# Org-wide search for PRs that mention OWNER/REPO#N. Catches implementing
# PRs in sibling repos that the issue body never names. Run even when no
# other repository is mentioned on the issue.
gh search prs --owner OWNER --state open --json number,url,title,repository,isDraft,state --limit 20 -- "OWNER/REPO#ISSUE_NUMBER"

# Keyword search for branch-style names that embed the issue number.
# GitHub's head: qualifier is exact, so search the text instead.
gh search prs --owner OWNER --state open --json number,url,title,repository,isDraft,state --limit 20 -- "agent/ISSUE_NUMBER"
gh search prs --owner OWNER --state open --json number,url,title,repository,isDraft,state --limit 20 -- "feat/ISSUE_NUMBER"

# View a specific PR, including review decision.
# reviewDecision: CHANGES_REQUESTED | APPROVED | REVIEW_REQUIRED | empty.
# state: OPEN | CLOSED | MERGED. Re-fetch before treating a PR as in-flight;
# CLOSED without MERGED means abandoned — do not error.
gh pr view NUMBER --repo OWNER/REPO --json state,title,body,comments,labels,mergedAt,isDraft,reviewDecision,reviewRequests,url

# CI check summary (pass / fail / pending per check). Exit code is 0 when
# all checks pass, 8 when checks are still pending, and nonzero (1) both
# when a check fails AND when no checks are configured at all — a bare
# nonzero exit is not itself a fetch error, so guard with `|| true` and
# inspect stdout/stderr rather than trusting the exit code alone. Empty
# stdout (or stderr noting no checks were found) means "no checks";
# report that, not a failure.
gh pr checks NUMBER --repo OWNER/REPO || true
```

## Repository Contents

```bash
# List root directory files
gh api repos/OWNER/REPO/contents/ --jq '.[].name'

# Read a specific file
gh api repos/OWNER/REPO/contents/PATH --jq '.content' | base64 -d
```

## Cross-Repo Searches

When looking for an implementing PR, run the org-wide `gh search prs` recipes in Pull Requests first — those find sibling-repo PRs without needing the other repo to be named. Use the commands below when the issue names a specific other repository (including one outside the org).

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
