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

## Existing-practice search

Before proposing a governance rule about a pattern, search `target_repo` for it — scope to that repo, not all of GitHub. Code search without a `repo:` qualifier covers every repository the sandbox token can access, including other private installation repos, and will inflate the file count. The `repo:` qualifier below is mandatory and must match the proposal's `target_repo`. Only paths are printed (no snippets), so no file content beyond a path is captured in `summary`.

The recipe uses `gh api` rather than `gh search code` because GitHub code search can return HTTP 200 with `incomplete_results: true` and fewer than 100 items, and `gh search code --json path` hides that flag.

```bash
# Example: before prohibiting exact gh CLI commands in SKILL.md
RESULT=$(gh api -X GET search/code \
  -f q='gh repo:<target_repo> filename:SKILL.md' -f per_page=100) \
  && echo "$RESULT" | jq -e '(.incomplete_results == false) and (.total_count <= 100) and (.items | type == "array")' >/dev/null \
  || { echo "SEARCH FAILED OR INCOMPLETE: treat as failed and drop the proposal per the shared skill's fail-closed rule" >&2; exit 1; }
echo "$RESULT" | jq '[.items[].path] | unique'
```

The check fails closed on an API error, `incomplete_results: true`, or a `total_count` above one page (100) — more matching files may exist outside the returned set — so do not report a count or name migration files from a partial set. This is a heuristic for the pattern token, not a parser of exact CLI invocations — review hits before counting them. If the results look ambiguous, treat the check as failed rather than guessing at a count.
