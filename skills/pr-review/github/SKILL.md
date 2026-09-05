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

# PR files list (paginated — loop if needed)
PR_FILES=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/files?per_page=100")

# Full unified diff
gh pr diff "${PR_NUMBER}" --repo "${REPO_FULL_NAME}"

# Per-file diff (for large PRs)
git diff <merge-base>..HEAD -- <file>
```

## File contents at PR head

```bash
# Fetch file contents at a specific ref (base64-encoded)
CONTENT=$(gh api "repos/${REPO_FULL_NAME}/contents/${FILE}?ref=${HEAD_SHA}" \
  --jq '.content // empty' 2>/dev/null)
echo "$CONTENT" | base64 --decode
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

## Review thread dismissals

Used by step 2a-1. One query carries all three dismissal signals —
replies, thread resolution, and 👎 reactions. GraphQL rather than REST:
resolution state is GraphQL-only (`pulls/.../comments` does not expose it
at all), reactions over REST cost an extra request per comment, and
GraphQL returns comments already grouped into threads, so there is no
`in_reply_to_id` chain to reconstruct. This is a read-only query — see
"GraphQL access" below.

```bash
DISMISSALS=$(gh api graphql \
  -f owner="${REPO_FULL_NAME%%/*}" -f name="${REPO_FULL_NAME##*/}" \
  -F pr="${PR_NUMBER}" -f query='
query($owner:String!,$name:String!,$pr:Int!){
 repository(owner:$owner,name:$name){ pullRequest(number:$pr){
  author{ login }
  comments(last:100){ nodes{ author{ login } authorAssociation } }
  reviews(last:100){ nodes{ author{ login } authorAssociation } }
  reviewThreads(last:100){
   pageInfo{ hasPreviousPage }
   nodes{
    isResolved
    resolvedBy{ login }
    comments(first:50){ pageInfo{ hasNextPage } nodes{
     author{ __typename login }
     authorAssociation
     body createdAt path diffHunk
     line originalLine startLine originalStartLine
     reactionGroups{ content reactors(first:10){ totalCount nodes{ ... on User { login } } } }
    }}
   }
  }}
 }
}')
```

Reading the response:

- `pullRequest.author.login` is the PR author, excluded from the trust
  boundary.
- `comments` and `reviews` exist for the trust lookup only: they carry
  the `authorAssociation` of everyone who wrote a PR-level comment or a
  review body, so resolvers and reactors can be tiered without an extra
  request. `last: 100` keeps the newest of each; the lookup is
  best-effort over what these return.
- Within a thread, `comments.nodes[0]` is the root comment and every later
  node is a reply — hence `first: 50` there, which must not become `last`.
  When a thread's own `comments.pageInfo.hasNextPage` is true its newest
  replies were not read, and "most recent qualifying reply wins" cannot be
  evaluated. Treat that thread as **undetermined** and dismiss nothing from
  it, rather than acting on a truncated view that may predate a reversal.
- `reviewThreads` returns **oldest-first**, so the query uses `last: 100`
  to keep the most recent threads, which are the ones a re-review needs.
  `pageInfo.hasPreviousPage` true means older threads were not read;
  continue rather than paginating, but do not read a thread's absence as
  the absence of a dismissal.
- `line` comes back null with `originalLine` set once a comment's diff
  position goes stale. On a re-review that is the common case, not the
  edge — always fall back to `originalLine`/`originalStartLine`.
- `reactionGroups` returns all eight reaction contents even at zero, so
  select `content == "THUMBS_DOWN"` and check `totalCount` before reading
  `reactors.nodes`.

**Bot logins have two spellings and this query returns both.** GraphQL
reports a `Bot`-typed `author.login` **without** the `[bot]` suffix —
`fullsend-ai-review`, which is the form `FULLSEND_SLUG` holds, so it
compares directly. REST reports that same comment's `user.login` **with**
the suffix, and a bot that resolved a thread appears under `resolvedBy`
typed `User` — also with the suffix. Compare each login against its own
source, or strip a trailing `[bot]` from both sides first.
[fullsend#6456](https://github.com/fullsend-ai/fullsend/issues/6456)
corrected this same mismatch in another skill.

Trust tiers come from `authorAssociation`, which the query returns on every
thread comment. Resolvers and reactors carry none of their own, so look
their login up among those associations first.

The last-resort lookup is the collaborator-permission endpoint:

```bash
# Collaborator permission fallback — cache per login.
# Requires push access; expect 403 under the review agent's read-only
# token and treat any error as "not trusted" (step 2a-1 fails closed).
gh api "repos/${REPO_FULL_NAME}/collaborators/${LOGIN}/permission" \
  --jq '.role_name'
```

The sandbox proxy permits it (a GET on `api.github.com`, `access:
read-only` in `policies/github/review.yaml`), but GitHub itself rejects
the call without push access — "Must have push access to view collaborator
permission." The review harness is `readonly_repo: true` with
`providers/github-ro.yaml`, so this is the expected result here, not a
misconfiguration.

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
