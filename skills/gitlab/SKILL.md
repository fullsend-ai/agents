---
name: gitlab
description: >-
  GitLab REST API commands for interacting with projects, issues, and merge
  requests via curl. Shared by all agents running on the GitLab forge.
---

# GitLab API

Use `curl` with the GitLab REST API. The environment provides `GITLAB_TOKEN`
for authentication. All requests include:

```bash
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/..."
```

Extract the host, project path, and issue IID from the issue URL:
```bash
GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
PROJECT_PATH=$(echo "${ISSUE_URL}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
PROJECT_ID=$(printf '%s' "${PROJECT_PATH}" | jq -sRr @uri)
ISSUE_IID=$(basename "${ISSUE_URL}")
```

## Issues

```bash
# View an issue with full details
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/issues/${ISSUE_IID}"

# List issue comments (notes)
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/issues/${ISSUE_IID}/notes?per_page=100&sort=asc"

# List open issues
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/issues?state=opened&per_page=100"

# Search issues by keyword
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/issues?state=opened&search=keyword&per_page=30"
```

## Merge Requests

```bash
# List open merge requests
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/merge_requests?state=opened&per_page=50"

# Search merge requests by keyword
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/merge_requests?state=opened&search=keyword&per_page=30"

# View a specific merge request
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/merge_requests/${MR_IID}"
```

## Repository Contents

```bash
# List root directory files
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/repository/tree"

# Read a specific file (raw content)
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/repository/files/$(printf '%s' 'path/to/file' | jq -sRr @uri)/raw?ref=main"
```

## Cross-Project Searches

```bash
# Search issues in another project (use URL-encoded project path)
OTHER_PROJECT_ID=$(printf '%s' "group/other-project" | jq -sRr @uri)
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${OTHER_PROJECT_ID}/issues?state=opened&search=keyword&per_page=30"

# Search merge requests in another project
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${OTHER_PROJECT_ID}/merge_requests?state=opened&search=keyword&per_page=30"
```

## Key Differences from GitHub

- Issues use `iid` (project-scoped) not `id` (global). Use `iid` in URLs.
- PRs are called "merge requests" (MRs). URL path is `/-/merge_requests/`.
- Project identifiers must be URL-encoded (`group%2Fsubgroup%2Fproject`).
- Labels are set as a comma-separated string via PUT, not individual POST/DELETE calls.
- Comments are called "notes" in the API.
