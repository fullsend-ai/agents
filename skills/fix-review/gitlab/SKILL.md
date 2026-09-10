---
name: fix-review-gitlab
description: >-
  GitLab REST API commands for fetching MR metadata and diffs in the fix agent.
  Use curl to view MR state, changes, and notes.
---

# Fix Review — GitLab API

Use `curl` with the GitLab REST API to fetch MR data for the fix agent.
The environment provides `GITLAB_TOKEN` for authentication.

Derive the API host and project path from the environment:

```bash
GITLAB_HOST=$(echo "${PR_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
```

## MR Metadata

```bash
# View MR with full details
curl --silent --config - \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" \
  <<< "header = \"PRIVATE-TOKEN: ${GITLAB_TOKEN}\""
```

## MR Diff

```bash
# Fetch the current diff (changes)
curl --silent --config - \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/changes" \
  <<< "header = \"PRIVATE-TOKEN: ${GITLAB_TOKEN}\"" \
  | jq -r '.changes[] | "--- a/\(.old_path)\n+++ b/\(.new_path)\n\(.diff)"'
```

## MR Notes

```bash
# List MR notes (comments, for context on prior iterations)
curl --silent --config - \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/notes?per_page=100&sort=asc" \
  <<< "header = \"PRIVATE-TOKEN: ${GITLAB_TOKEN}\""
```
