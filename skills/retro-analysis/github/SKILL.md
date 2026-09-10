---
name: retro-analysis-github
description: >
  GitHub-specific CLI recipes for the retro-analysis skill. Use gh CLI
  to trace workflow runs, read logs, download artifacts, and search for
  duplicate issues on GitHub.
---

# Retro Analysis — GitHub CLI Recipes

## Workflow tracing

### From an issue

```bash
# Find triage dispatches (triggered by /fs-triage or label events)
gh run list --repo "$REPO_FULL_NAME" --workflow=fullsend.yaml \
  --json databaseId,status,conclusion,event,createdAt \
  -q '.[] | select(.event == "issue_comment" or .event == "issues")'
```

```bash
# Find the corresponding agent runs in the dispatch repo
gh run list --repo "$DISPATCH_REPO" --workflow=triage.yml --limit 10 \
  --json databaseId,status,conclusion,createdAt
```

```bash
# If the issue reached ready-to-code, find code dispatches
gh run list --repo "$DISPATCH_REPO" --workflow=code.yml --limit 10 \
  --json databaseId,status,conclusion,createdAt
```

### From a PR

```bash
# Find review dispatches
gh run list --repo "$DISPATCH_REPO" --workflow=review.yml --limit 10 \
  --json databaseId,status,conclusion,createdAt
```

```bash
# Find fix dispatches (if review requested changes)
gh run list --repo "$DISPATCH_REPO" --workflow=fix.yml --limit 10 \
  --json databaseId,status,conclusion,createdAt
```

## Reading agent logs and artifacts

```bash
# View job outcomes
gh run view <RUN_ID> --repo "$DISPATCH_REPO" --json jobs \
  -q '.jobs[] | "\(.name) \(.status)/\(.conclusion)"'

# Search logs for errors
gh run view <RUN_ID> --repo "$DISPATCH_REPO" --log 2>&1 \
  | grep -i "error\|fail\|exit code"

# Download session artifacts (JSONL traces)
gh run download <RUN_ID> --repo "$DISPATCH_REPO"
```

## Discovering the agents repo

```bash
# From an agent workflow run log, extract the agents repo
gh run view <RUN_ID> --repo "$DISPATCH_REPO" --log 2>&1 \
  | grep -oP 'Fetching agent \S+ from \K[^@]+' \
  | head -1
```

## Duplicate search

```bash
# Broad keyword search across title and body
gh api \
  "search/issues?q=<topic+keywords>+repo:<target_repo>+is:issue+is:open&per_page=20" \
  --jq '.items[] | {number: .number, title: .title, url: .html_url, body: .body}'
```

Use multiple searches with different keyword combinations if the first returns no results — the same idea can be filed under different titles.
