---
name: pr-review-gitlab
description: >-
  GitLab-specific CLI commands for the MR review orchestrator. Provides
  curl commands against the GitLab REST API used to fetch MR data,
  diffs, file contents, and issue context during review.
---

# PR Review — GitLab CLI Reference

This skill provides GitLab-specific CLI commands for the MR review
orchestrator. The orchestrator (`pr-review` skill) delegates data
fetching to these commands when `FULLSEND_FORGE=gitlab`.

## Environment setup

```bash
# Derive project variables from PR_URL
GITLAB_HOST=$(echo "${PR_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
REPO=$(echo "${PR_URL}" | sed -E 's|^https://[^/]+/(.+)/-/merge_requests/[0-9]+$|\1|')
REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
MR_IID=$(basename "${PR_URL}")
```

## MR data fetching

```bash
# Write token into a stable curl config file so the header never
# appears on a command line (avoids the tirith sensitive-upload rule).
# Use a hardcoded path, not a mktemp path stored in a shell variable:
# each fenced block in this file runs as an independent Bash call, so
# shell variables do not survive between them — files (at a fixed,
# predictable path) do. Written and scrubbed within this same block so
# the token never outlives the calls that need it.
(umask 077; printf 'header = "PRIVATE-TOKEN: %s"\n' "${GITLAB_TOKEN}" > /tmp/gitlab-api.curlrc)

# MR metadata: title, description, author, labels, draft status, head SHA
MR_DATA=$(curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${MR_IID}")
HEAD_SHA=$(echo "$MR_DATA" | jq -r '.sha')
IS_DRAFT=$(echo "$MR_DATA" | jq -r '.draft')

# MR changes (includes diff per file), saved for later Bash calls
# (shell variables do not survive between calls; files do)
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${MR_IID}/changes" \
  > /sandbox/workspace/mr-changes.json

# Changed file paths
jq -r '.changes[].new_path' /sandbox/workspace/mr-changes.json

: > /tmp/gitlab-api.curlrc
```

## Unified diff (small and large MRs)

```bash
# Per-file diffs from the changes payload, written to disk for the sub-agents
# to Read; generated files dropped. An empty file is a tool failure.
jq -r '.changes[] | select(.new_path | test("(^|/)(vendor|node_modules)/|(package-lock\\.json|go\\.sum|yarn\\.lock|\\.pb\\.go)$") | not)
  | "### File: \(.new_path)\n\(.diff)"' /sandbox/workspace/mr-changes.json > /sandbox/workspace/pr-diff.txt
test -s /sandbox/workspace/pr-diff.txt || echo "EMPTY DIFF — produce a failure result (reason tool-failure)"
```

## Materialise MR head files

```bash
# Every changed file at HEAD_SHA → /sandbox/workspace/pr-head/<path>
# (16 fetches in flight); manifest beside the tree, never inside it.
# Scanner dialect (fullsend-ai/agents#1190): `test` not `[ ]`, no
# nested $( ), no glob `case` arm after a literal one, no rm; the token
# goes through a curl config file, never the command line.
# Run this call with a 600 s tool timeout, then scrub the config file in
# its own call (see below) whether this one succeeded, failed or timed out.
PR_HEAD=/sandbox/workspace/pr-head; WORK=/sandbox/workspace/pr-head.work; MANIFEST=/sandbox/workspace/pr-head.manifest
CHANGES=/sandbox/workspace/mr-changes.json; CURLRC=/tmp/pr-head.curlrc
API="https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/repository/files"
mkdir -p "$PR_HEAD" "$WORK"; : > "$MANIFEST"; : > "$WORK/failed"; FETCH_START=$(date +%s)
OLDMASK=$(umask); umask 077; printf 'header = "PRIVATE-TOKEN: %s"\nfail\nsilent\n' "$GITLAB_TOKEN" > "$CURLRC"; umask "$OLDMASK"
jq -r '.changes[] | select(.deleted_file) | "removed \(.new_path)"' "$CHANGES" >> "$MANIFEST"
jq -r '.changes[] | select(.deleted_file | not) | .new_path
  | select(test("\n") or startswith("/") or test("(^|/)\\.\\.(/|$)")) | "unsafe \(. | @json)"' "$CHANGES" >> "$MANIFEST"
jq -r '.changes[] | select(.deleted_file | not) | .new_path
  | select((test("\n") or startswith("/") or test("(^|/)\\.\\.(/|$)")) | not) | "\(@uri) \(.)"' "$CHANGES" > "$WORK/files"
n=0
while IFS=' ' read -r enc f; do
  mkdir -p "$PR_HEAD/$(dirname -- "$f")"
  curl -K "$CURLRC" "${API}/${enc}/raw?ref=${HEAD_SHA}" > "$PR_HEAD/$f" || printf '%s\n' "$f" >> "$WORK/failed" &
  n=$(( n + 1 )); test "$(( n % 16 ))" -eq 0 && wait
done < "$WORK/files"
wait
while IFS=' ' read -r enc f; do
  dest="$PR_HEAD/$f"
  if grep -qxF -e "$f" "$WORK/failed"; then echo "failed $f"
  elif ! test -f "$dest"; then echo "failed $f"
  elif test "$(wc -c < "$dest")" -gt 2097152; then echo "too-large $f"
  elif test -s "$dest" && ! grep -Iq '' "$dest"; then echo "binary $f"
  else echo "ok $f"; fi >> "$MANIFEST"
done < "$WORK/files"
sort -o "$MANIFEST" "$MANIFEST"; : > "$CURLRC"
FETCH_END=$(date +%s); OK=$(grep -c '^ok ' "$MANIFEST" || true); ALL=$(wc -l < "$MANIFEST")
echo "pr-head: $OK of $ALL files ok in $(( FETCH_END - FETCH_START ))s"
```

Then, as its own Bash call — whether the call above succeeded, failed or
timed out — scrub the token: `: > /tmp/pr-head.curlrc`.

## Issue context

```bash
# Recreate the curl config for this block (see MR data fetching above
# for why a stable path, not a mktemp variable, is used).
(umask 077; printf 'header = "PRIVATE-TOKEN: %s"\n' "${GITLAB_TOKEN}" > /tmp/gitlab-api.curlrc)

# Fetch linked issue metadata
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/<issue-iid>" \
  | jq '{title, description}'

# Fetch issue notes (comments)
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/<issue-iid>/notes"

: > /tmp/gitlab-api.curlrc
```

## Prior review comparison

```bash
# Recreate the curl config for this block (see MR data fetching above
# for why a stable path, not a mktemp variable, is used).
(umask 077; printf 'header = "PRIVATE-TOKEN: %s"\n' "${GITLAB_TOKEN}" > /tmp/gitlab-api.curlrc)

# Compare commits between prior review and current HEAD
COMPARE=$(curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/repository/compare?from=${PRIOR_REVIEW_SHA}&to=${HEAD_SHA}")
CHANGED_FILES=$(echo "$COMPARE" | jq -r '.diffs[].new_path')

: > /tmp/gitlab-api.curlrc
```

Each block above writes and scrubs `/tmp/gitlab-api.curlrc` within its
own Bash call. As a fallback in case a block is interrupted before its
own scrub line runs, once every GitLab API call in this skill is done
for the review, scrub the token again as its own explicit Bash call:
`: > /tmp/gitlab-api.curlrc` — not `rm`, and not an `EXIT` trap (a trap
set in one Bash call does not fire for commands run in a later,
independent call, and would instead delete the file before the later
consumers ever read it).

## Notes

- The sandbox policy allows `curl` but not `gh` for GitLab forges.
- All write mutations are handled by the post-script on the runner —
  the sandbox token is read-only.
- The orchestrator produces `agent-result.json` using the same schema
  regardless of forge. The post-script's `forge_post_review()` handles
  forge-specific review posting.
