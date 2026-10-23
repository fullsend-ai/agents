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

Run both passes for every proposal — fix-keyed and root-cause-keyed (see the
retro-analysis skill's "Before proposing" section).

**Search scope.** The fix-keyed pass searches the proposal's `target_repo`. The
root-cause pass must search **every repo the localization rules can route a
proposal to** — platform (`fullsend-ai/fullsend`), the discovered agents repo,
and the source repo (`$REPO_FULL_NAME`) — because a symptom fix and its root
cause can land in different layers (the #1931-workaround vs #1887-root-cause
case). Combine them with repeated `repo:` qualifiers, which GitHub OR-joins. Do
**not** use `org:` — it reaches private/unrelated sibling repos and risks leaking
private content into a public proposal.

```bash
# Fix-keyed: keyword search across title and body, open issues, in target_repo
gh api \
  "search/issues?q=<fix+keywords>+repo:<target_repo>+is:issue+is:open&per_page=20" \
  --jq '.items[] | {repo: (.repository_url | sub(".*/repos/"; "")), number: .number, title: .title, url: .html_url, body: .body}'

# Root-cause-keyed: subsystem/component keywords across the three layer repos
# the routing rules name — platform, agents, and source ($REPO_FULL_NAME).
# Name all three explicitly (not <target_repo>, which is only whichever layer
# this proposal routes to, and not org:, which reaches private/unrelated repos).
# No is:open — the close-reason rules (duplicate / not planned / completed) must
# apply across layers, so this returns closed issues too, with state_reason and
# closed_at projected for the 30-day not-planned rule.
gh api \
  "search/issues?q=<subsystem+or+root-cause+keywords>+repo:fullsend-ai/fullsend+repo:<agents-repo>+repo:$REPO_FULL_NAME+is:issue&per_page=20" \
  --jq '.items[] | {repo: (.repository_url | sub(".*/repos/"; "")), number: .number, title: .title, state: .state, state_reason: .state_reason, closed_at: .closed_at, url: .html_url, body: .body}'

# Fix-keyed closed issues: the fix-keyed pass above is open-only, so this
# applies the close-reason rules to fix-keyed hits in target_repo.
gh api \
  "search/issues?q=<fix+keywords>+repo:<target_repo>+is:issue+is:closed&per_page=20" \
  --jq '.items[] | {repo: (.repository_url | sub(".*/repos/"; "")), number: .number, title: .title, state: .state, state_reason: .state_reason, closed_at: .closed_at, url: .html_url, body: .body}'

# Follow a duplicate chain to its canonical. GitHub's native "close as duplicate"
# stores the canonical as structured data (GraphQL Issue.duplicateOf), NOT as
# text — gh issue view --json has no field for it, so query it first:
gh api graphql -f query='
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) {
        stateReason
        duplicateOf { number state stateReason url }
      }
    }
  }' -f owner=<owner> -f name=<repo> -F number=<candidate-number> \
  --jq '.data.repository.issue'
# When duplicateOf is null (duplicate recorded only in prose), fall back to the
# candidate's own body and comments for a "duplicate of #X" reference:
gh issue view <candidate-number> --repo <candidate-repo> \
  --json number,title,state,stateReason,body,comments \
  --jq '{number, title, state, stateReason, body, comments: [.comments[].body]}'
# Then fetch the referenced canonical directly (follow further links if it is
# itself a duplicate). Note its repo: the canonical may live in another layer.

# Reverse-reference search (distinct use): find issues/PRs that mention a
# candidate, e.g. a later issue that supersedes it.
gh api \
  "search/issues?q=<candidate-number>+repo:<target_repo>+is:issue&per_page=20" \
  --jq '.items[] | {number: .number, title: .title, state: .state, url: .html_url, body: .body}'
```

Record each considered candidate in `related_issues.found` using its
fully-qualified `owner/repo#N` form whenever it is not in the proposal's
`target_repo` — a bare `#N` renders as a link to `target_repo` and would point
at the wrong issue. Same-repo candidates may stay as the bare integer.

Use multiple searches with different keyword combinations if the first returns no results — the same idea can be filed under different titles.
