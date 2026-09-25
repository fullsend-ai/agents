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

## Merge Requests

```bash
# List open merge requests
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests?state=opened&per_page=50"

# Search merge requests by keyword
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests?state=opened&search=keyword&per_page=30"

# View a specific merge request. Inspect `state` (opened / closed / merged),
# `draft`, and `head_pipeline.status` (success / failed / running / pending /
# canceled / skipped / null). Re-fetch before treating an MR as in-flight;
# closed without merged means abandoned — do not error.
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${MR_IID}"

# Approval / review status (approved vs still pending)
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${MR_IID}/approvals"

# Find MRs referencing a specific issue (targeted lookup for Existing-MR gate).
# Same-project; follow with the group search below for sibling projects.
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/related_merge_requests"

# Find MRs that would close a specific issue
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/closed_by"

# Group-wide listing of opened MRs whose title/description mention this
# issue. Catches implementing MRs in sibling projects that the issue body
# never names. Run even when no other project is mentioned on the issue.
# scope=all is required — the group merge-request list defaults to
# scope=created_by_me, so without it the response silently omits MRs
# authored by other users or bots, which is exactly the case this search
# exists to catch. Check the HTTP status: a 403/404 on the group endpoint
# means the search failed (e.g. insufficient access to the group), not
# that there are no matches — record that as an information gap.
# PARENT_GROUP is REPO with the last path segment removed
# (group/subgroup/project → group/subgroup).
PARENT_GROUP=$(echo "${REPO}" | sed -E 's|/[^/]+$||')
PARENT_ENCODED=$(printf '%s' "${PARENT_GROUP}" | jq -sRr @uri)
ISSUE_REF=$(printf '%s' "${REPO}#${ISSUE_NUMBER}" | jq -sRr @uri)
GROUP_MR_RESPONSE=$(curl --silent --write-out '\n%{http_code}' --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/groups/${PARENT_ENCODED}/merge_requests?state=opened&scope=all&search=${ISSUE_REF}&per_page=20")
GROUP_MR_STATUS=$(echo "${GROUP_MR_RESPONSE}" | tail -n1)
GROUP_MR_BODY=$(echo "${GROUP_MR_RESPONSE}" | sed '$d')
# GROUP_MR_STATUS != 200 is a search failure, not "no matches" — note it
# in `reasoning` as an information gap per agents/triage.md rather than
# concluding no implementing MR exists.
```

## Project Visibility

Before naming a candidate MR's project or PR/MR details in a public comment
(see `agents/triage.md`'s Visibility check), fetch the project's
`visibility` — the merge-request and issue endpoints above return
`web_url`/`source_project_id`, not `visibility`; it only appears on the
project resource itself. Check both the issue's own project and the
candidate project.

```bash
# Visibility of a project: public | internal | private.
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}" | jq -r '.visibility'

# Same call for the candidate project surfaced by a search above
# (e.g. "group/candidate-project" from a group-wide or cross-project result).
CANDIDATE_ENCODED=$(printf '%s' "group/candidate-project" | jq -sRr @uri)
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${CANDIDATE_ENCODED}" | jq -r '.visibility'
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

When looking for an implementing MR, run the group-wide search recipe in Merge Requests first — that finds sibling-project MRs without needing the other project to be named. Use the commands below when the issue names a specific other project (including one outside the parent group).

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
