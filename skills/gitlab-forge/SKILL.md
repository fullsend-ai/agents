---
name: gitlab
description: >-
  Use when interacting with GitLab projects, issues, or merge requests via curl
  against the GitLab REST API. Shared by all agents running on the GitLab forge.
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
REPO=$(echo "${ISSUE_URL}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
ISSUE_NUMBER=$(basename "${ISSUE_URL}")
```

## Issues

```bash
# View an issue with full details
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}"

# List issue comments (notes)
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=asc"

# List open issues
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues?state=opened&per_page=100"

# Search issues by keyword
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues?state=opened&search=keyword&per_page=30"
```

## Re-check Data

Note authors with their creation time, for the end-of-run re-check.

```bash
# Scanner dialect: the token goes through a curl config file, never the
# command line; no `break` in a loop. Run as written.
RC=/tmp/recheck.curlrc
OLDMASK=$(umask); umask 077; printf 'header = "PRIVATE-TOKEN: %s"\nfail\nsilent\n' "$GITLAB_TOKEN" > "$RC"; umask "$OLDMASK"

# Notes newer than the run start, newest first. Page 1 holds the newest 100;
# when it is full and its last note is still newer than the run start, fetch
# page=2 the same way.
curl -K "$RC" -o /tmp/recheck-notes.json "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=desc&page=1"
jq -c --arg since "$FULLSEND_RUN_STARTED_AT" '.[] | select(.system != true)
  | select((.created_at | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdate) > ($since | fromdate))
  | {username: .author.username, author_id: .author.id, at: .created_at, fullsend: ((.body // "") | contains("<!-- fullsend:")), body}' /tmp/recheck-notes.json

# The note author object has no `bot` field: for the marked notes only, look
# each author up and read it. Run as written (no `break`).
jq -r '.[] | select(.system != true) | select((.body // "") | contains("<!-- fullsend:")) | .author.id' /tmp/recheck-notes.json | sort -u > /tmp/recheck-marked-authors.txt
while read -r uid; do
  curl -K "$RC" -o "/tmp/recheck-user-${uid}.json" "https://${GITLAB_HOST}/api/v4/users/${uid}"
  jq -c '{id, username, bot}' "/tmp/recheck-user-${uid}.json"
done < /tmp/recheck-marked-authors.txt
: > "$RC"
```

`select(.system != true)` drops GitLab's state notes. `fullsend` marks a
body carrying the marker; it excludes the note only when the author's `bot`
field on `users/:id` is true — a person's note is never excluded, marker or
not, and without that lookup a marked note is kept as context. The exact username of a bot that authored a marked note is fullsend's
login, never a pattern; `bot` tells a bot from a person, never the username's
shape, and other bots stay in as context. The `since` filter normalises GitLab's fractional seconds
and offset before comparing.

## Merge Requests

```bash
# List open merge requests
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests?state=opened&per_page=50"

# Search merge requests by keyword
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests?state=opened&search=keyword&per_page=30"

# View a specific merge request
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${MR_IID}"

# Find MRs referencing a specific issue (targeted lookup for Existing-MR gate)
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/related_merge_requests"

# Find MRs that would close a specific issue
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/closed_by"
```

## Repository Contents

```bash
# List root directory files
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/repository/tree"

# Read a specific file (raw content)
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/repository/files/$(printf '%s' 'path/to/file' | jq -sRr @uri)/raw?ref=main"
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
- Labels support atomic `add_labels` and `remove_labels` parameters on issue PUT — no read-modify-write cycle needed.
- Comments are called "notes" in the API.
