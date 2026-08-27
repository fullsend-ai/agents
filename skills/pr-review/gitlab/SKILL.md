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
# MR metadata: title, description, author, labels, draft status, head SHA
MR_DATA=$(curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${MR_IID}")
HEAD_SHA=$(echo "$MR_DATA" | jq -r '.sha')
IS_DRAFT=$(echo "$MR_DATA" | jq -r '.draft')

# MR changes (includes diff per file)
MR_CHANGES=$(curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${MR_IID}/changes")

# Changed file paths
echo "$MR_CHANGES" | jq -r '.changes[].new_path'
```

## File contents at MR head

```bash
# Fetch file contents at a specific ref (base64-encoded)
FILE_ENCODED=$(printf '%s' "${FILE}" | jq -sRr @uri)
CONTENT=$(curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/repository/files/${FILE_ENCODED}?ref=${HEAD_SHA}" \
  | jq -r '.content // empty')
echo "$CONTENT" | base64 --decode
```

## Issue context

```bash
# Fetch linked issue metadata
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/<issue-iid>" \
  | jq '{title, description}'

# Fetch issue notes (comments)
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/<issue-iid>/notes"
```

## Prior review comparison

```bash
# Compare commits between prior review and current HEAD
COMPARE=$(curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/repository/compare?from=${PRIOR_REVIEW_SHA}&to=${HEAD_SHA}")
CHANGED_FILES=$(echo "$COMPARE" | jq -r '.diffs[].new_path')
```

## Review thread dismissals

Not implemented for GitLab. Step 2a-1 checks for this section and skips
when a forge does not provide it, so re-reviews on GitLab keep today's
behavior rather than failing.

The signals do exist here and parity is a reasonable follow-up: MR
discussions expose `resolved` and `resolved_by` per note
(`/merge_requests/<iid>/discussions`), replies are the notes after the
first in a discussion, and 👎 is the `award_emoji` sub-resource on a note
(`thumbsdown`). What is missing is a verified mapping onto the three
signals — in particular which field carries the note author's project
role, since the trust boundary in step 2a-1 is the part that must not be
approximated. Anyone adding it should confirm that against a live
instance rather than from the API docs.

## Notes

- The sandbox policy allows `curl` but not `gh` for GitLab forges.
- All write mutations are handled by the post-script on the runner —
  the sandbox token is read-only.
- The orchestrator produces `agent-result.json` using the same schema
  regardless of forge. The post-script's `forge_post_review()` handles
  forge-specific review posting.
