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

# PR files list — every page, flattened, saved for later Bash calls
# (shell variables do not survive between calls; files do)
gh api --paginate --slurp "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/files?per_page=100" \
  | jq 'add // []' > /sandbox/workspace/pr-files.json
FILE_COUNT=$(jq 'length' /sandbox/workspace/pr-files.json)
LINE_COUNT=$(jq '[.[] | .additions + .deletions] | add // 0' /sandbox/workspace/pr-files.json)
```

## Full unified diff (small PRs)

```bash
# Written to disk for the sub-agents to Read; an empty file is a tool failure
gh pr diff "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" > /sandbox/workspace/pr-diff.txt
test -s /sandbox/workspace/pr-diff.txt || echo "EMPTY DIFF — produce a failure result (reason tool-failure)"
```

## Per-file diffs (large PRs)

```bash
# From the files API — the checkout is the base branch, so never `git diff` it.
# Generated files are dropped here.
jq -r '.[] | select(.filename | test("(^|/)(vendor|node_modules)/|(package-lock\\.json|go\\.sum|yarn\\.lock|\\.pb\\.go)$") | not)
  | "### File: \(.filename)\n\(.patch // "(no patch from the API: binary or oversized)")"' \
  /sandbox/workspace/pr-files.json > /sandbox/workspace/pr-diff.txt
test -s /sandbox/workspace/pr-diff.txt || echo "EMPTY DIFF — produce a failure result (reason tool-failure)"
```

## Materialise PR head files

```bash
# Every changed file at HEAD_SHA → /sandbox/workspace/pr-head/<path>
# (16 fetches in flight); manifest beside the tree, never inside it.
# Scanner dialect (fullsend-ai/agents#1190): `test` not `[ ]`, no
# nested $( ), no glob `case` arm after a literal one, no rm.
# Run this call with a 600 s tool timeout.
PR_HEAD=/sandbox/workspace/pr-head; WORK=/sandbox/workspace/pr-head.work; MANIFEST=/sandbox/workspace/pr-head.manifest
FILES=/sandbox/workspace/pr-files.json
mkdir -p "$PR_HEAD" "$WORK"; : > "$MANIFEST"; : > "$WORK/failed"; FETCH_START=$(date +%s)
jq -r '.[] | select(.status == "removed") | "removed \(.filename)"' "$FILES" >> "$MANIFEST"
jq -r '.[] | select(.status != "removed") | .filename
  | select(test("\n") or startswith("/") or test("(^|/)\\.\\.(/|$)")) | "unsafe \(. | @json)"' "$FILES" >> "$MANIFEST"
jq -r '.[] | select(.status != "removed") | .filename
  | select((test("\n") or startswith("/") or test("(^|/)\\.\\.(/|$)")) | not)' "$FILES" > "$WORK/files"
n=0
while IFS= read -r f; do
  mkdir -p "$PR_HEAD/$(dirname -- "$f")"
  gh api -H "Accept: application/vnd.github.raw+json" "repos/$REPO_FULL_NAME/contents/$f?ref=$HEAD_SHA" > "$PR_HEAD/$f" 2>/dev/null || printf '%s\n' "$f" >> "$WORK/failed" &
  n=$(( n + 1 )); test "$(( n % 16 ))" -eq 0 && wait
done < "$WORK/files"
wait
while IFS= read -r f; do
  dest="$PR_HEAD/$f"
  if grep -qxF -e "$f" "$WORK/failed"; then echo "failed $f"
  elif ! test -f "$dest"; then echo "failed $f"
  elif test "$(wc -c < "$dest")" -gt 2097152; then echo "too-large $f"
  elif test -s "$dest" && ! grep -Iq '' "$dest"; then echo "binary $f"
  else echo "ok $f"; fi >> "$MANIFEST"
done < "$WORK/files"
sort -o "$MANIFEST" "$MANIFEST"
FETCH_END=$(date +%s); OK=$(grep -c '^ok ' "$MANIFEST" || true); ALL=$(wc -l < "$MANIFEST")
echo "pr-head: $OK of $ALL files ok in $(( FETCH_END - FETCH_START ))s"
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

## Re-check Data

The end-of-run re-check needs the current head and the activity created after
the run started, with the author and time of each. `--paginate` is required:
an active PR exceeds one page.

```bash
# Current head SHA (through a file: the scanner cannot resolve a gh call
# inside $( ), see fullsend-ai/agents#1190). Run as written.
gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}" > /tmp/recheck-pr.json
NEW_HEAD_SHA=$(jq -r '.head.sha' /tmp/recheck-pr.json)

# Activity newer than the run start: general PR comments, reviews (whose
# field is submitted_at, not created_at), inline review comments. Each goes
# through a file — gh's --jq takes one expression and has no --arg.
gh api --paginate "repos/${REPO_FULL_NAME}/issues/${PR_NUMBER}/comments" > /tmp/recheck-comments.json
jq -c --arg since "$FULLSEND_RUN_STARTED_AT" '.[] | select((.created_at | fromdate) > ($since | fromdate))
  | {login: .user.login, type: .user.type, at: .created_at, fullsend: ((.body // "") | contains("<!-- fullsend:")), body}' /tmp/recheck-comments.json
gh api --paginate "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/reviews" > /tmp/recheck-reviews.json
jq -c --arg since "$FULLSEND_RUN_STARTED_AT" '.[] | select(((.submitted_at // empty) | fromdate) > ($since | fromdate))
  | {login: .user.login, type: .user.type, at: .submitted_at, fullsend: ((.body // "") | contains("<!-- fullsend:")), body}' /tmp/recheck-reviews.json
gh api --paginate "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/comments" > /tmp/recheck-review-comments.json
jq -c --arg since "$FULLSEND_RUN_STARTED_AT" '.[] | select((.created_at | fromdate) > ($since | fromdate))
  | {login: .user.login, type: .user.type, at: .created_at, fullsend: ((.body // "") | contains("<!-- fullsend:")), body}' /tmp/recheck-review-comments.json

# Delta from the dispatched head to the current one, when they differ. The
# REST compare is always merge-base...head, so it is the tree diff only while
# status is "ahead"; "diverged" means a force-push, 300 files means a cut list.
gh api "repos/${REPO_FULL_NAME}/compare/${FULLSEND_RUN_HEAD_SHA}...${NEW_HEAD_SHA}" \
  --jq '{status, total_commits, file_count: (.files | length),
         files: [.files[] | {filename, previous_filename, status, patch}]}'
```

`fullsend` marks a body carrying the marker; it excludes the item only when
`type` is `"Bot"` — a human's comment is never excluded, marker or not.
Fullsend's exact logins are `fullsend-ai-${FULLSEND_ROLE}[bot]` and any App
login that authored a marked comment on this PR, never a pattern; `type`
tells an App from a human, never the login's shape, and other Apps stay in
as context. The `since` filter parses both timestamps, as the other forges do.
The delta is complete only when `status` is `ahead` and `file_count` is under
300; a 404 means the dispatched head is gone, and anything else is
unverified. A rename sets `previous_filename` and an empty `patch`.

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
