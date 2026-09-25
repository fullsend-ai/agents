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

## Flapping detection

Recipes for the shared retro-analysis flapping section. Name `fix.yml`
explicitly — `finding-agent-runs` does not list it. Use `--limit 10`
(not 5).

### Bound run discovery

Read `PR_CREATED_AT` / `PR_UPDATED_AT` from
`gh pr view PR_NUMBER --repo PR_REPO --json createdAt,updatedAt`.

Fix and review runs live in the PR lifetime:

```bash
gh run list --repo "$DISPATCH_REPO" --workflow=fix.yml --limit 10 \
  --created "${PR_CREATED_AT}..${PR_UPDATED_AT}" \
  --json databaseId,status,conclusion,createdAt,updatedAt,event

gh run list --repo "$DISPATCH_REPO" --workflow=review.yml --limit 10 \
  --created "${PR_CREATED_AT}..${PR_UPDATED_AT}" \
  --json databaseId,status,conclusion,createdAt,updatedAt,event
```

Code runs create the PR, so their `createdAt` is earlier than
`PR.createdAt`. Do not use the PR-lifetime window for `code.yml` — it
drops the first file-changing run.

```bash
gh run list --repo "$DISPATCH_REPO" --workflow=code.yml --limit 10 \
  --created "<=${PR_CREATED_AT}" \
  --json databaseId,status,conclusion,createdAt,updatedAt,event
```

Match a code run by parsing `event_payload`: `issue.number` from the
`agent/{issue}-{slug}` branch, then confirm the run log prints
`PR_REPO/pull/PR_NUMBER`.

### Compare patches

For each file-changing run except the code run:

- start = that run's `pull_request.head.sha` (dispatch-time, pre-run)
- end = the next review run's `pull_request.head.sha` (the output commit)

For the code run (no `pull_request` object):

- start = `gh pr view PR_NUMBER --repo PR_REPO --json baseRefOid --jq .baseRefOid`
  (or the merge-base of that base and the first review run's `head.sha`)
- end = the first review run's `pull_request.head.sha`

```bash
gh api "repos/${PR_REPO}/compare/${START}...${END}" \
  --jq '.files[] | {filename, patch}'
```

### Check results at an output-anchor SHA

Pattern 2 needs the named check at each run's *output* anchor (the
following review run's `head.sha`), not at dispatch-time `head.sha` and
not `gh pr checks` (that is the current PR head only).

```bash
gh api "repos/${PR_REPO}/commits/${SHA}/check-runs" \
  --jq '.check_runs[] | {name, conclusion}'
```

For the last file-changing run, use the PR head at retro time. Checks
are keyed to the commit, so they remain queryable after rebase.

Also paginate the PR's review comments and findings. Pattern 3
correlates finding text across cycles.

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
