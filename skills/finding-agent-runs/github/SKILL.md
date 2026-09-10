---
name: finding-agent-runs-github
description: >
  GitHub-specific CLI recipes for finding agent workflow runs using
  the gh CLI. Use when tracing agent dispatches on GitHub.
---

# Finding Agent Runs — GitHub CLI Recipes

## Issue → Agent Runs

### Triage dispatch

```bash
gh run list --workflow=fullsend.yaml \
  --json databaseId,status,conclusion,event,createdAt \
  -q '.[] | select(.event == "issue_comment")'
```

Match by timestamp against the `/fs-triage` comment (`gh issue view <N> --json comments`), then confirm `dispatch-triage` succeeded:

```bash
gh run view <RUN_ID> --json jobs \
  -q '.jobs[] | "\(.name) \(.status)/\(.conclusion)"'
```

### Code dispatch

```bash
gh run list --workflow=fullsend.yaml \
  --json databaseId,status,conclusion,event,createdAt \
  -q '.[] | select(.event == "issues")'
```

Confirm `dispatch-code completed/success` in the jobs list.

### Find the actual agent run

```bash
gh run list --repo "${DISPATCH_REPO}" --workflow=triage.yml --limit 5 \
  --json databaseId,status,conclusion,createdAt

gh run list --repo "${DISPATCH_REPO}" --workflow=code.yml --limit 5 \
  --json databaseId,status,conclusion,createdAt
```

## PR → Agent Runs

### Review dispatch

```bash
gh run list --workflow=fullsend.yaml \
  --json databaseId,status,conclusion,event,headBranch,createdAt \
  -q '.[] | select(.event == "pull_request_target")'
```

Confirm `dispatch-review completed/success`, then find the run:

```bash
gh run list --repo "${DISPATCH_REPO}" --workflow=review.yml --limit 5 \
  --json databaseId,status,conclusion,createdAt
```

### Retro dispatch

```bash
gh run list --workflow=fullsend.yaml \
  --json databaseId,status,conclusion,event,createdAt \
  -q '.[] | select(.event == "pull_request_target" or .event == "issue_comment")'
```

Find the actual retro agent run:

```bash
gh run list --repo "${DISPATCH_REPO}" --workflow=retro.yml --limit 5 \
  --json databaseId,status,conclusion,createdAt
```

## GitHub-specific failure signatures

| Log message | Meaning |
|-------------|---------|
| `remote rejected ... without 'workflows' permission` | Agent modified `.github/workflows/` without permission |

## Logs and artifacts

```bash
# Search logs for errors
gh run view <RUN_ID> --repo "${DISPATCH_REPO}" --log 2>&1 \
  | grep -i "error\|fail\|exit code"

# Download session artifact
gh run download <RUN_ID> --repo "${DISPATCH_REPO}"
```
