---
name: jira
description: >-
  Jira Cloud REST API commands for reading issue content, comments, and
  searching for duplicate or related issues via curl. Shared by all agents
  running on the Jira forge.
---

# Jira Cloud API

Use `curl` with the Jira Cloud REST API (v3). The environment provides
`JIRA_USER_EMAIL` and `JIRA_TOKEN` for Basic auth, and `JIRA_BASE_URL` for
the instance host. All requests include:

```bash
curl --silent --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
  --header "Content-Type: application/json" \
  "${JIRA_BASE_URL}/rest/api/3/..."
```

Extract the issue key and project key from the issue URL:
```bash
ISSUE_KEY=$(echo "${ISSUE_URL}" | sed -E 's|.*/browse/||')
PROJECT_KEY="${ISSUE_KEY%-*}"
```

Jira Cloud only (v1) — the issue host must be `*.atlassian.net`. Jira
Server/Data Center is not supported.

## Issues

```bash
# View an issue with full details
curl --silent --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
  "${JIRA_BASE_URL}/rest/api/3/issue/${ISSUE_KEY}"

# List issue comments
curl --silent --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
  "${JIRA_BASE_URL}/rest/api/3/issue/${ISSUE_KEY}/comment?orderBy=created"

# List open issues in the project
curl --silent --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
  --get --data-urlencode "jql=project = ${PROJECT_KEY} AND statusCategory != Done" \
  "${JIRA_BASE_URL}/rest/api/3/search"
```

## Searching for Duplicates and Related Issues

```bash
# Search issues by keyword (JQL text search)
curl --silent --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
  --get --data-urlencode "jql=project = ${PROJECT_KEY} AND text ~ \"keyword\"" \
  "${JIRA_BASE_URL}/rest/api/3/search"

# Search across all projects visible to the account
curl --silent --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
  --get --data-urlencode "jql=text ~ \"keyword\" ORDER BY updated DESC" \
  "${JIRA_BASE_URL}/rest/api/3/search"
```

## Cross-Project Searches

```bash
# Search issues in another project (use its project key)
curl --silent --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
  --get --data-urlencode "jql=project = OTHERPROJ AND text ~ \"keyword\"" \
  "${JIRA_BASE_URL}/rest/api/3/search"
```

## Key Differences from GitHub/GitLab

- Jira has no pull/merge requests — it is a pure issue tracker. There is no
  equivalent "code change" search.
- Issue descriptions and comment bodies are Atlassian Document Format (ADF)
  JSON, not plain text/markdown — read `.fields.description` or a comment's
  `.body` as ADF and extract `.content[].content[].text` for plain text.
- Search uses JQL (Jira Query Language) via the `jql` query parameter, not a
  free-text `search` parameter.
- Labels are a flat string array on `.fields.labels` — there is no separate
  per-project label registry to query.
