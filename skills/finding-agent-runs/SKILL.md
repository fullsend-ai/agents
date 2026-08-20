---
name: finding-agent-runs
description: >
  Use when an agent hasn't posted results, a workflow run failed, or you need
  to find the workflow run for a fullsend triage, code, or review agent
  given an issue number or PR number
---

# Finding Agent Runs

Given an issue or PR, find the fullsend agent workflow runs. Use the
forge-specific finding-agent-runs skill for CLI recipes (GitHub or GitLab).

## Setup

```bash
ORG=$(echo "${REPO_FULL_NAME:-}" | cut -d/ -f1)
DISPATCH_REPO="${ORG}/.fullsend"
```

The shim workflow runs in the source repo on `main`. It dispatches to
`${DISPATCH_REPO}` which runs the agent workflows (triage, code, review, retro).

## Issue → Agent Runs

### Triage dispatch

Triage dispatches from issue comment events (the `/fs-triage` command).
Match by timestamp against the `/fs-triage` comment, then confirm dispatch succeeded.

### Code dispatch

Code dispatches from issue events when `ready-to-code` is applied.
Confirm `dispatch-code completed/success` in the jobs list.

### Find the actual agent run

Match by timestamp in the dispatch repo (runs start within seconds).

## PR → Agent Runs

### Code agent run

The PR branch follows `agent/{issue}-{slug}`. Extract the issue number and
use the issue recipe above to find the code dispatch.

### Review dispatch

Review dispatches from pull request events. Match by branch name.

### Retro dispatch

Retro dispatches from pull request events (on PR close) and from
issue comment events (the `/fs-retro` command).

## Reference

### Common failure signatures

| Log message | Meaning |
|-------------|---------|
| `Agent exit code: 0` + `Post-script failed` | Agent succeeded but post-script (push/commit) failed |
| `Agent exit code: 1` | Agent failed — check session artifact |
