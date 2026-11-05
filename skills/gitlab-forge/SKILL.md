---
name: gitlab
description: >-
  Use when interacting with GitLab projects, issues, or merge requests via curl
  against the GitLab REST API. Shared by all agents running on the GitLab forge.
---

# GitLab API

Use `curl` with the GitLab REST API. The environment provides `GITLAB_TOKEN`
for authentication.

The sandbox's command scanner blocks any command that passes the token as a
`--header "PRIVATE-TOKEN: …"` argument (`analysis_incomplete`). Pass it
through a curl config file instead (fullsend-ai/agents#1190). Write the file
once, before your first request. Only your user can read it.

Run this setup command in its own Bash tool call. Do not combine it with any
GitLab fetch or other command in the same call; the scanner blocks a call that
mixes token-config setup with a request.

```bash
(umask 077; set -C; rm -f /tmp/gitlab-api.curlrc; printf 'header = "PRIVATE-TOKEN: %s"\nsilent\n' "$GITLAB_TOKEN" > /tmp/gitlab-api.curlrc)
```

Make every request in a separate, later Bash tool call. Each request reads
that file with `-K`:

```bash
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/..."
```

Do not put the token back on the command line or wrap the request in another
shell to get it past the scanner. If a request is still blocked, report that
you could not read the data. Do not continue as if you had read it.

The same applies when the sandbox's SSRF protection or network policy denies
a request, for example because `GITLAB_HOST` resolves to a private address the
policy does not authorize. A denial is final. Make no further requests to that
host. Do not retry with an alternate URL, host or IP form, header, curl option,
or environment variable. Report that the request was denied and follow your
agent's instructions for denied requests.

When you have made your last GitLab request, scrub the token in its own Bash
call: `: > /tmp/gitlab-api.curlrc`. If you need another request after that,
run the setup command again.

Extract the host, project path, and issue IID from the issue URL:
```bash
GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
REPO=$(echo "${ISSUE_URL}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
ISSUE_NUMBER=$(basename "${ISSUE_URL}")
```

## Issues

```bash
# View an issue with full details
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}"

# List issue comments (notes)
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=asc"

# List open issues
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues?state=opened&per_page=100"

# Search issues by keyword
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues?state=opened&search=keyword&per_page=30"
```

## Merge Requests

```bash
# List open merge requests
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests?state=opened&per_page=50"

# Search merge requests by keyword
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests?state=opened&search=keyword&per_page=30"

# View a specific merge request
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${MR_IID}"

# Find MRs referencing a specific issue (targeted lookup for Existing-MR gate)
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/related_merge_requests"

# Find MRs that would close a specific issue
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/closed_by"
```

## Repository Contents

```bash
# List root directory files
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/repository/tree"

# Read a specific file (raw content)
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/repository/files/$(printf '%s' 'path/to/file' | jq -sRr @uri)/raw?ref=main"
```

## Cross-Project Searches

```bash
# Search issues in another project (use URL-encoded project path)
OTHER_PROJECT_ID=$(printf '%s' "group/other-project" | jq -sRr @uri)
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${OTHER_PROJECT_ID}/issues?state=opened&search=keyword&per_page=30"

# Search merge requests in another project
curl -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${OTHER_PROJECT_ID}/merge_requests?state=opened&search=keyword&per_page=30"
```

## Key Differences from GitHub

- Issues use `iid` (project-scoped) not `id` (global). Use `iid` in URLs.
- PRs are called "merge requests" (MRs). URL path is `/-/merge_requests/`.
- Project identifiers must be URL-encoded (`group%2Fsubgroup%2Fproject`).
- Labels support atomic `add_labels` and `remove_labels` parameters on issue PUT — no read-modify-write cycle needed.
- Comments are called "notes" in the API.
