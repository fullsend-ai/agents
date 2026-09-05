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
  comments(last:100){ nodes{ author{ login } body createdAt } }
  reviews(last:100){ nodes{ author{ login } body createdAt } }
  reviewThreads(last:100){
   pageInfo{ hasPreviousPage }
   nodes{
    isResolved
    resolvedBy{ login }
    comments(first:50){ pageInfo{ hasNextPage } nodes{
     author{ __typename login }
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

- `pullRequest.author.login` is the PR author, who can never dismiss a
  finding (their refutations are still heard — see step 2a-1).
- `comments` and `reviews` carry the text of PR-level comments and
  review bodies, because a dismissal or a refutation is as often written
  there as in the thread it belongs to. `last: 100` keeps the newest of
  each and truncates once a PR has more: an older PR-level dismissal may
  go unread, and its absence from these nodes is not evidence that it was
  never written. They carry no thread anchor either, so step 2a-1 applies
  one only when it names a single finding unambiguously.
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
  `reactors.nodes`. `first: 10` truncates the list when `totalCount`
  exceeds it: a login's absence from `nodes` is then not evidence that
  they did not react, and nothing may be concluded from it either way.

**Bot logins have two spellings and this query returns both.** GraphQL
reports a `Bot`-typed `author.login` **without** the `[bot]` suffix —
`fullsend-ai-review`, which is the form `FULLSEND_SLUG` holds, so it
compares directly. REST reports that same comment's `user.login` **with**
the suffix, and a bot that resolved a thread appears under `resolvedBy`
typed `User` — also with the suffix. Compare each login against its own
source, or strip a trailing `[bot]` from both sides first.
[fullsend#6456](https://github.com/fullsend-ai/fullsend/issues/6456)
corrected this same mismatch in another skill.

**Authorization to dismiss is the effective repository role, and
nothing else.** The query deliberately does not select
`authorAssociation`: `OWNER`/`MEMBER`/`COLLABORATOR` describe a
relationship, not a permission, and fullsend
[ADR 0054](https://github.com/fullsend-ai/fullsend/blob/main/docs/ADRs/0054-require-authorization-on-all-agent-dispatch-paths.md)
rejected `author_association` as authorization evidence for the same
reason. There is no association fallback to reach for. Resolve the role
per login, cache it, and accept only `admin`, `maintain`, or `write`:

```bash
# Effective repository role — the only dismissal gate. Cache per login.
# Requires push access; expect 403 under the review agent's read-only
# token and treat any error as unverified (step 2a-1 fails closed).
gh api "repos/${REPO_FULL_NAME}/collaborators/${LOGIN}/permission" \
  --jq '.role_name'
```

The sandbox proxy permits it (a GET on `api.github.com`, `access:
read-only` in `policies/github/review.yaml`), but GitHub itself rejects
the call without push access — "Must have push access to view collaborator
permission." The review harness is `readonly_repo: true` with
`providers/github-ro.yaml`, so this is the expected result here, not a
misconfiguration: under it most dismissals stay unverified and their
findings stay actionable, which step 2a-1 requires the review to state
in one line. Resolving the role on the runner and passing a normalized
role into the sandbox would close that, but no issue tracks that
transport yet;
[fullsend#6860](https://github.com/fullsend-ai/fullsend/issues/6860)
documents the authorization model this gate follows, not the transport.
Interactive mode below is unaffected: a token with push access answers
this call, so the gate verifies there today.

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
