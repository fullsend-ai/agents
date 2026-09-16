---
name: fix-review-github
description: >-
  GitHub CLI commands for fetching PR metadata and diffs in the fix agent.
  Use gh to view PR state, diff, and comments.
---

# Fix Review — GitHub CLI

Use the `gh` CLI to fetch PR data for the fix agent. The environment
provides `GH_TOKEN` for authentication.

## PR Metadata

```bash
# View PR with full details
gh pr view "${PR_NUMBER}" --json number,title,body,headRefName,baseRefName,state,files,labels

# View PR state only
gh pr view "${PR_NUMBER}" --json state --jq '.state'
```

## PR Diff

```bash
# Fetch the current diff
gh pr diff "${PR_NUMBER}"
```

## Review findings fallback

The review bot posts findings as an issue comment marked
`<!-- fullsend:review-agent -->`, not as a PR review body. COMMENT and
CHANGES_REQUESTED reviews write a pointer into the formal review body
("See the [review comment](...) for full details."). When
`/sandbox/workspace/review-body.txt` is empty, whitespace-only,
pointer-only, or under 200 bytes, fetch the latest matching issue
comment. Use jq `last` (not `tail -1`) because comment bodies contain
newlines.

On bot-triggered runs, `TRIGGER_SOURCE` is the review bot's exact login,
so match it directly instead of the broader `-review[bot]` suffix. On
human-triggered runs `TRIGGER_SOURCE` is the human's username, not the
bot's login, so keep the suffix match there.

```bash
REVIEW_BODY_FILE="/sandbox/workspace/review-body.txt"
if [ ! -s "${REVIEW_BODY_FILE}" ] || ! grep -q '[^[:space:]]' "${REVIEW_BODY_FILE}" ||
   grep -qxE 'See the .*review comment.*for full details\.?' "${REVIEW_BODY_FILE}" ||
   [ "$(wc -c < "${REVIEW_BODY_FILE}")" -lt 200 ]; then
  if [[ "${TRIGGER_SOURCE}" == *"[bot]" ]]; then
    LOGIN_SELECT='select(.user.login == env.TRIGGER_SOURCE)'
  else
    LOGIN_SELECT='select(.user.login | endswith("-review[bot]"))'
  fi
  REVIEW_COMMENT=$(gh api --paginate --slurp "repos/${REPO_FULL_NAME}/issues/${PR_NUMBER}/comments" \
    | jq -r "add // [] | [.[] | ${LOGIN_SELECT} | select(.body | contains(\"<!-- fullsend:review-agent -->\"))] | last | .body // empty")
  if [ -n "${REVIEW_COMMENT}" ]; then
    echo "::notice::Recovered review findings from issue comment API fallback"
    printf '%s\n' "${REVIEW_COMMENT}" > "${REVIEW_BODY_FILE}"
  else
    echo "::error::No review body found at ${REVIEW_BODY_FILE} and API fallback found no review comment"
  fi
fi
cat "${REVIEW_BODY_FILE}"
```
